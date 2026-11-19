import Foundation
import OpenTUICore

extension Merman {
    // MARK: - Sequence Placement (`sequence/placement.ts`)

    // parity: merman/src/sequence/placement.ts#SequenceHorizontalBounds [status=implemented hash=a98f12fd64c0]
    public struct SequenceHorizontalBounds: Equatable, Hashable, Sendable, Codable {
        public var leftX: Int
        public var rightX: Int

        public init(leftX: Int, rightX: Int) {
            self.leftX = leftX
            self.rightX = rightX
        }
    }

    // parity: merman/src/sequence/placement.ts#SequenceParticipantPlacement [status=implemented hash=412cb53c72e5]
    public struct SequenceParticipantPlacement: Equatable, Hashable, Sendable, Codable {
        public var participant: SequenceParticipant
        public var centerX: Int
        public var headerLeftX: Int
        public var headerRightX: Int
        public var labelLines: [String]

        public init(
            participant: SequenceParticipant,
            centerX: Int,
            headerLeftX: Int,
            headerRightX: Int,
            labelLines: [String]
        ) {
            self.participant = participant
            self.centerX = centerX
            self.headerLeftX = headerLeftX
            self.headerRightX = headerRightX
            self.labelLines = labelLines
        }
    }

    // parity: merman/src/sequence/placement.ts#SequenceGroupPlacement [status=implemented hash=91000559259a]
    public struct SequenceGroupPlacement: Equatable, Hashable, Sendable, Codable {
        public var group: SequenceParticipantGroup
        public var labelText: String
        public var leftX: Int
        public var rightX: Int

        public init(group: SequenceParticipantGroup, labelText: String, leftX: Int, rightX: Int) {
            self.group = group
            self.labelText = labelText
            self.leftX = leftX
            self.rightX = rightX
        }
    }

    // parity: merman/src/sequence/placement.ts#SequenceWallPlacement [status=implemented hash=81f2a2ee0697]
    public struct SequenceWallPlacement: Equatable, Hashable, Sendable, Codable {
        public var bounds: SequenceHorizontalBounds
        public var startY: Int
        public var endY: Int

        public init(bounds: SequenceHorizontalBounds, startY: Int, endY: Int) {
            self.bounds = bounds
            self.startY = startY
            self.endY = endY
        }
    }

    // parity: merman/src/sequence/placement.ts#SequenceActivationPlacement [status=implemented hash=0712455e7ce7]
    public struct SequenceActivationPlacement: Equatable, Hashable, Sendable, Codable {
        public var participant: String
        public var centerX: Int
        public var startY: Int
        public var endY: Int
        public var depth: Int

        public init(participant: String, centerX: Int, startY: Int, endY: Int, depth: Int) {
            self.participant = participant
            self.centerX = centerX
            self.startY = startY
            self.endY = endY
            self.depth = depth
        }
    }

    // parity: merman/src/sequence/placement.ts#SequenceStepPlacement [status=implemented hash=ba0aa2a17bf1]
    public enum SequenceStepPlacement: Equatable, Hashable, Sendable, Codable {
        case note(note: SequenceNote, textLines: [String], textX: Int, textY: Int)
        case fragment(
            fragment: SequenceFragment,
            labelText: String,
            bounds: SequenceHorizontalBounds,
            y: Int,
            wallsBefore: SequenceWallPlacement?
        )
        case message(
            message: SequenceMessage,
            labelLines: [String],
            labelX: Int,
            labelY: Int,
            arrowY: Int,
            fromX: Int,
            toX: Int,
            leftX: Int,
            rightX: Int,
            headX: Int,
            direction: Int,
            inlineLabel: String?
        )
        case selfMessage(
            message: SequenceMessage,
            labelLines: [String],
            centerX: Int,
            rightX: Int,
            topY: Int,
            bottomY: Int
        )
    }

    public struct SequenceRowsLayout: Equatable, Hashable, Sendable, Codable {
        public var participantHeaderTopY: Int
        public var participantHeaderY: Int
        public var participantRuleY: Int
        public var lifelineStartY: Int
        public var lifelineEndY: Int

        public init(
            participantHeaderTopY: Int,
            participantHeaderY: Int,
            participantRuleY: Int,
            lifelineStartY: Int,
            lifelineEndY: Int
        ) {
            self.participantHeaderTopY = participantHeaderTopY
            self.participantHeaderY = participantHeaderY
            self.participantRuleY = participantRuleY
            self.lifelineStartY = lifelineStartY
            self.lifelineEndY = lifelineEndY
        }
    }

    // parity: merman/src/sequence/placement.ts#SequencePlacementPlan [status=implemented hash=65f0cb1ee455]
    public struct SequencePlacementPlan: Equatable, Hashable, Sendable, Codable {
        public var width: Int
        public var height: Int
        public var rows: SequenceRowsLayout
        public var participants: [SequenceParticipantPlacement]
        public var groups: [SequenceGroupPlacement]
        public var activations: [SequenceActivationPlacement]
        public var steps: [SequenceStepPlacement]

        public init(
            width: Int,
            height: Int,
            rows: SequenceRowsLayout,
            participants: [SequenceParticipantPlacement],
            groups: [SequenceGroupPlacement],
            activations: [SequenceActivationPlacement],
            steps: [SequenceStepPlacement]
        ) {
            self.width = width
            self.height = height
            self.rows = rows
            self.participants = participants
            self.groups = groups
            self.activations = activations
            self.steps = steps
        }
    }

    private struct SequenceGroupRange {
        let group: SequenceParticipantGroup
        let startIndex: Int
        let endIndex: Int
    }

    private struct SequencePendingFragmentFrame {
        let startIndex: Int
        var bounds: SequenceHorizontalBounds
    }

    private struct SequenceActiveFragmentFrame {
        let bounds: SequenceHorizontalBounds
        var boundaryY: Int
    }

    private static let seqNoteHorizontalPadding = 2
    private static let seqGroupHorizontalPadding = 2
    private static let seqFragmentHorizontalOverhang = 3

    private static func seqMermaidLabelLines(_ label: String) -> [String] {
        let matches = regexAllMatches(#"(?:<br\s*/?\s*>|\\n)"#, in: label, options: [.caseInsensitive])
        var lines: [String] = []
        var cursor = label.startIndex
        for match in matches {
            lines.append(trimTrailingWhitespace(String(label[cursor..<match.range.lowerBound])))
            cursor = match.range.upperBound
        }
        lines.append(trimTrailingWhitespace(String(label[cursor...])))
        return lines.isEmpty ? [""] : lines
    }

    static func trimTrailingWhitespace(_ value: String) -> String {
        var end = value.endIndex
        while end > value.startIndex {
            let prev = value.index(before: end)
            if value[prev].isWhitespace {
                end = prev
            } else {
                break
            }
        }
        return String(value[..<end])
    }

    private static func seqLabelLinesWidth(_ lines: [String]) -> Int {
        lines.reduce(0) { max($0, diagramTextWidth($1)) }
    }

    private static func seqNoteLabelLines(_ label: String) -> [String] {
        let lines = seqMermaidLabelLines(label)
        let width = seqLabelLinesWidth(lines)
        let padding = String(repeating: " ", count: seqNoteHorizontalPadding)
        return lines.map { line in
            let trail = max(0, width - diagramTextWidth(line))
            return "\(padding)\(line)\(String(repeating: " ", count: trail))\(padding)"
        }
    }

    private static func seqMessageLabelText(_ message: SequenceMessage) -> String {
        guard let num = message.number else { return message.label }
        return "\(num). \(message.label)"
    }

    private static func seqParticipantHeaderWidth(_ label: String, compact: Bool) -> Int {
        let width = seqLabelLinesWidth(seqMermaidLabelLines(label))
        return compact ? width : max(3, width)
    }

    private static func seqFragmentLabelText(_ fragment: SequenceFragment) -> String {
        if fragment.kind == .end { return "" }
        let prefix = fragment.kind == .loop ? "↻ loop" : fragment.kind.rawValue
        return " \(prefix): \(fragment.label) "
    }

    private static func seqMessageWidth(_ message: SequenceMessage) -> Int {
        seqLabelLinesWidth(seqMermaidLabelLines(seqMessageLabelText(message)))
    }

    private static func seqSelfMessageLoopWidthForLines(_ labelLines: [String]) -> Int {
        max(10, seqLabelLinesWidth(labelLines) + 4)
    }

    private static func seqSelfMessageLoopWidth(_ message: SequenceMessage) -> Int {
        seqSelfMessageLoopWidthForLines(seqMermaidLabelLines(seqMessageLabelText(message)))
    }

    private static func seqArrowHeadX(_ toX: Int, direction: Int, head: SequenceArrowHead?) -> Int {
        head == nil ? toX : toX - direction
    }

    private static func seqInlineMessageLabel(
        _ message: SequenceMessage,
        labelLines: [String],
        fromX: Int,
        toX: Int,
        compact: Bool
    ) -> String? {
        if !compact || message.from == message.to || labelLines.count != 1 { return nil }
        let label = " \(labelLines[0]) "
        return diagramTextWidth(label) <= abs(toX - fromX) - 3 ? label : nil
    }

    private static func seqGetStepHeight(
        _ step: SequenceStep,
        centers: [Int],
        participantIndexes: [String: Int],
        compact: Bool
    ) -> Int {
        switch step {
        case .note(let note):
            return seqNoteLabelLines(note.label).count + 2
        case .activation:
            return 0
        case .fragment:
            return 2
        case .message(let msg):
            let labelLines = seqMermaidLabelLines(seqMessageLabelText(msg))
            if let fromIdx = participantIndexes[msg.from],
               let toIdx = participantIndexes[msg.to],
               seqInlineMessageLabel(msg, labelLines: labelLines, fromX: centers[fromIdx], toX: centers[toIdx], compact: compact) != nil
            {
                return 2
            }
            return labelLines.count + (msg.from == msg.to ? 3 : 2)
        }
    }

    private static func seqGetParticipantIndexes(_ map: [String: Int], ids: [String]) -> [Int] {
        ids.compactMap { map[$0] }
    }

    private static func seqGroupLabelText(_ group: SequenceParticipantGroup) -> String {
        group.label.isEmpty ? "" : " \(group.label) "
    }

    private static func seqGetGroupRanges(_ diagram: SequenceDiagram, participantIndexes: [String: Int]) -> [SequenceGroupRange] {
        diagram.groups.compactMap { group in
            let idxs = seqGetParticipantIndexes(participantIndexes, ids: group.participantIds)
            guard let lo = idxs.min(), let hi = idxs.max() else { return nil }
            return SequenceGroupRange(group: group, startIndex: lo, endIndex: hi)
        }
    }

    private static func seqGetStepParticipantIndexes(_ step: SequenceStep, participantIndexes: [String: Int]) -> [Int] {
        switch step {
        case .message(let msg):
            return seqGetParticipantIndexes(participantIndexes, ids: [msg.from, msg.to])
        case .note(let note):
            return seqGetParticipantIndexes(participantIndexes, ids: note.over)
        case .activation, .fragment:
            return []
        }
    }

    private static func seqGetStepContentBounds(
        _ step: SequenceStep,
        centers: [Int],
        participantIndexes: [String: Int]
    ) -> SequenceHorizontalBounds? {
        switch step {
        case .message(let msg):
            guard let fromIndex = participantIndexes[msg.from],
                  let toIndex = participantIndexes[msg.to]
            else { return nil }
            let fromX = centers[fromIndex]
            let toX = centers[toIndex]
            if fromIndex == toIndex {
                return SequenceHorizontalBounds(leftX: fromX, rightX: fromX + seqSelfMessageLoopWidth(msg))
            }
            let leftX = min(fromX, toX)
            let rightX = max(fromX, toX)
            let labelWidth = seqMessageWidth(msg)
            let labelLeftX = leftX + 2
            return SequenceHorizontalBounds(leftX: min(leftX, labelLeftX), rightX: max(rightX, labelLeftX + labelWidth - 1))
        case .note(let note):
            let idxs = seqGetParticipantIndexes(participantIndexes, ids: note.over)
            guard let lo = idxs.min(), let hi = idxs.max() else { return nil }
            let centerX = floorDiv(centers[lo] + centers[hi], 2)
            let textLines = seqNoteLabelLines(note.label)
            let width = seqLabelLinesWidth(textLines)
            let leftX: Int
            if note.position == .left {
                leftX = centerX - width - 2
            } else if note.position == .right {
                leftX = centerX + 2
            } else {
                leftX = centerX - floorDiv(width, 2)
            }
            return SequenceHorizontalBounds(leftX: leftX, rightX: leftX + width - 1)
        case .activation, .fragment:
            return nil
        }
    }

    private static func seqResolveGroupBounds(
        _ diagram: SequenceDiagram,
        centers: [Int],
        participantIndexes: [String: Int],
        groupRanges: [SequenceGroupRange],
        compact: Bool
    ) -> [SequenceGroupPlacement] {
        groupRanges.map { range in
            var contentLeftX = centers[range.startIndex]
            var contentRightX = centers[range.endIndex]
            for i in range.startIndex...range.endIndex {
                let headerWidth = seqParticipantHeaderWidth(diagram.participants[i].label, compact: compact)
                let headerStartX = centers[i] - floorDiv(headerWidth, 2)
                contentLeftX = min(contentLeftX, headerStartX)
                contentRightX = max(contentRightX, headerStartX + headerWidth - 1)
            }
            for step in diagram.steps {
                let idxs = seqGetStepParticipantIndexes(step, participantIndexes: participantIndexes)
                if idxs.isEmpty || !idxs.allSatisfy({ $0 >= range.startIndex && $0 <= range.endIndex }) { continue }
                if let bounds = seqGetStepContentBounds(step, centers: centers, participantIndexes: participantIndexes) {
                    contentLeftX = min(contentLeftX, bounds.leftX)
                    contentRightX = max(contentRightX, bounds.rightX)
                }
            }
            let labelText = seqGroupLabelText(range.group)
            var leftX = contentLeftX - seqGroupHorizontalPadding
            var rightX = contentRightX + seqGroupHorizontalPadding
            let extraWidth = max(0, diagramTextWidth(labelText) + 4 - (rightX - leftX + 1))
            leftX -= floorDiv(extraWidth, 2)
            rightX += ceilDiv(extraWidth, 2)
            return SequenceGroupPlacement(group: range.group, labelText: labelText, leftX: leftX, rightX: rightX)
        }
    }

    private static func seqExpandHorizontalBounds(_ bounds: inout SequenceHorizontalBounds, leftX: Int, rightX: Int) {
        bounds.leftX = min(bounds.leftX, leftX)
        bounds.rightX = max(bounds.rightX, rightX)
    }

    private static func seqGetDiagramContentBounds(
        _ diagram: SequenceDiagram,
        centers: [Int],
        participantIndexes: [String: Int],
        compact: Bool
    ) -> SequenceHorizontalBounds {
        var bounds = SequenceHorizontalBounds(leftX: 0, rightX: 0)
        for i in 0..<diagram.participants.count {
            let headerWidth = seqParticipantHeaderWidth(diagram.participants[i].label, compact: compact)
            let labelStartX = centers[i] - floorDiv(headerWidth, 2)
            seqExpandHorizontalBounds(&bounds, leftX: labelStartX, rightX: labelStartX + headerWidth - 1)
        }
        for step in diagram.steps {
            if let content = seqGetStepContentBounds(step, centers: centers, participantIndexes: participantIndexes) {
                seqExpandHorizontalBounds(&bounds, leftX: content.leftX, rightX: content.rightX)
            }
        }
        return bounds
    }

    private static func seqGetFragmentFrameBounds(
        _ centers: [Int],
        fragment: SequenceFragment,
        nestingDepth: Int = 0
    ) -> SequenceHorizontalBounds? {
        guard let leftParticipantX = centers.first, let rightParticipantX = centers.last else { return nil }
        let leftX = leftParticipantX - seqFragmentHorizontalOverhang + nestingDepth
        let participantRightX = rightParticipantX + seqFragmentHorizontalOverhang - nestingDepth
        return SequenceHorizontalBounds(
            leftX: leftX,
            rightX: max(participantRightX, leftX + 2 + diagramTextWidth(seqFragmentLabelText(fragment)) + 1)
        )
    }

    private static func seqGetFragmentFrameBoundsByStep(
        _ centers: [Int],
        steps: [SequenceStep],
        participantIndexes: [String: Int]
    ) -> [Int: SequenceHorizontalBounds] {
        var boundsByStep: [Int: SequenceHorizontalBounds] = [:]
        var activeFrames: [SequencePendingFragmentFrame] = []
        for (index, step) in steps.enumerated() {
            guard case .fragment(let fragment) = step else {
                if let content = seqGetStepContentBounds(step, centers: centers, participantIndexes: participantIndexes) {
                    for i in 0..<activeFrames.count {
                        seqExpandHorizontalBounds(&activeFrames[i].bounds, leftX: content.leftX - 1, rightX: content.rightX + 1)
                    }
                }
                continue
            }
            guard let bounds = seqGetFragmentFrameBounds(centers, fragment: fragment, nestingDepth: activeFrames.count) else {
                continue
            }
            if fragment.kind == .alt || fragment.kind == .loop {
                activeFrames.append(SequencePendingFragmentFrame(startIndex: index, bounds: bounds))
                continue
            }
            guard !activeFrames.isEmpty else { continue }
            seqExpandHorizontalBounds(&activeFrames[activeFrames.count - 1].bounds, leftX: bounds.leftX, rightX: bounds.rightX)
            if fragment.kind != .end { continue }
            let closed = activeFrames.removeLast()
            boundsByStep[closed.startIndex] = closed.bounds
            if !activeFrames.isEmpty {
                seqExpandHorizontalBounds(
                    &activeFrames[activeFrames.count - 1].bounds,
                    leftX: closed.bounds.leftX - 1,
                    rightX: closed.bounds.rightX + 1
                )
            }
        }
        for frame in activeFrames {
            boundsByStep[frame.startIndex] = frame.bounds
        }
        return boundsByStep
    }

    private static func seqResolveParticipantCenters(
        _ diagram: SequenceDiagram,
        participantIndexes: [String: Int],
        minParticipantGap: Int,
        compact: Bool
    ) -> [Int] {
        var gaps: [Int] = []
        if diagram.participants.count > 1 {
            gaps.reserveCapacity(diagram.participants.count - 1)
            for index in 0..<(diagram.participants.count - 1) {
                let left = diagram.participants[index]
                let right = diagram.participants[index + 1]
                gaps.append(max(
                    minParticipantGap,
                    ceilDiv(seqParticipantHeaderWidth(left.label, compact: compact), 2)
                        + ceilDiv(seqParticipantHeaderWidth(right.label, compact: compact), 2)
                        + 6
                ))
            }
        }

        for message in diagram.messages {
            let fromIndex = participantIndexes[message.from] ?? -1
            let toIndex = participantIndexes[message.to] ?? -1
            if fromIndex == toIndex && fromIndex >= 0 && fromIndex < diagram.participants.count - 1 {
                gaps[fromIndex] = max(
                    gaps[fromIndex],
                    seqSelfMessageLoopWidth(message)
                        + ceilDiv(seqLabelLinesWidth(seqMermaidLabelLines(diagram.participants[fromIndex + 1].label)), 2)
                        + 2
                )
                continue
            }
            if fromIndex < 0 || toIndex < 0 || abs(fromIndex - toIndex) != 1 { continue }
            let gapIndex = min(fromIndex, toIndex)
            gaps[gapIndex] = max(gaps[gapIndex], seqMessageWidth(message) + 6)
        }

        for step in diagram.steps {
            guard case .note(let note) = step else { continue }
            let idxs = seqGetParticipantIndexes(participantIndexes, ids: note.over)
            if idxs.count == 1, let pos = note.position, pos != .over {
                let pIdx = idxs[0]
                let gapIndex = pos == .left ? pIdx - 1 : pIdx
                if gapIndex >= 0 && gapIndex < gaps.count {
                    gaps[gapIndex] = max(gaps[gapIndex], seqLabelLinesWidth(seqNoteLabelLines(note.label)) + 4)
                }
                continue
            }
            if idxs.count != 2 || abs(idxs[0] - idxs[1]) != 1 { continue }
            let gapIndex = min(idxs[0], idxs[1])
            gaps[gapIndex] = max(gaps[gapIndex], seqLabelLinesWidth(seqNoteLabelLines(note.label)) + 4)
        }

        var centers = [max(1, floorDiv(seqParticipantHeaderWidth(diagram.participants.first?.label ?? "", compact: compact), 2))]
        if diagram.participants.count > 1 {
            for i in 1..<diagram.participants.count {
                centers.append(centers[i - 1] + gaps[i - 1])
            }
        }
        return centers
    }

    private static func seqSeparateExpandedGroupsFromExternalParticipants(
        _ diagram: SequenceDiagram,
        centers: [Int],
        participantIndexes: [String: Int],
        ranges: [SequenceGroupRange],
        compact: Bool
    ) -> [Int] {
        var adjusted = centers
        guard adjusted.count > 1 else { return adjusted }
        for boundary in 0..<(adjusted.count - 1) {
            let groups = seqResolveGroupBounds(diagram, centers: adjusted, participantIndexes: participantIndexes, groupRanges: ranges, compact: compact)
            let leftWidth = seqParticipantHeaderWidth(diagram.participants[boundary].label, compact: compact)
            let rightWidth = seqParticipantHeaderWidth(diagram.participants[boundary + 1].label, compact: compact)
            var leftRight = adjusted[boundary] - floorDiv(leftWidth, 2) + leftWidth - 1
            var rightLeft = adjusted[boundary + 1] - floorDiv(rightWidth, 2)
            var bordersGroup = false

            for (index, range) in ranges.enumerated() {
                if range.endIndex == boundary {
                    leftRight = max(leftRight, groups[index].rightX)
                    bordersGroup = true
                }
                if range.startIndex == boundary + 1 {
                    rightLeft = min(rightLeft, groups[index].leftX)
                    bordersGroup = true
                }
            }

            if !bordersGroup { continue }
            let shift = leftRight + seqGroupHorizontalPadding + 1 - rightLeft
            if shift <= 0 { continue }
            for participantIndex in (boundary + 1)..<adjusted.count {
                adjusted[participantIndex] += shift
            }
        }
        return adjusted
    }

    // parity: merman/src/sequence/placement.ts#createSequencePlacementPlan [status=implemented hash=eba88bd2e907]
    public static func createSequencePlacementPlan(
        _ diagram: SequenceDiagram,
        options: SequenceDiagramRenderOptions = SequenceDiagramRenderOptions()
    ) -> SequencePlacementPlan {
        if diagram.participants.isEmpty {
            return SequencePlacementPlan(
                width: 0,
                height: 0,
                rows: SequenceRowsLayout(
                    participantHeaderTopY: 0,
                    participantHeaderY: 0,
                    participantRuleY: 0,
                    lifelineStartY: 0,
                    lifelineEndY: 0
                ),
                participants: [],
                groups: [],
                activations: [],
                steps: []
            )
        }
        let indexes = Dictionary(uniqueKeysWithValues: diagram.participants.enumerated().map { ($0.element.id, $0.offset) })
        let compact = options.compact ?? false
        var centers = seqResolveParticipantCenters(
            diagram,
            participantIndexes: indexes,
            minParticipantGap: normalizeSequenceMinParticipantGap(options.minParticipantGap),
            compact: compact
        )
        let ranges = seqGetGroupRanges(diagram, participantIndexes: indexes)
        centers = seqSeparateExpandedGroupsFromExternalParticipants(
            diagram,
            centers: centers,
            participantIndexes: indexes,
            ranges: ranges,
            compact: compact
        )
        var groups = seqResolveGroupBounds(diagram, centers: centers, participantIndexes: indexes, groupRanges: ranges, compact: compact)
        var contentBounds = seqGetDiagramContentBounds(diagram, centers: centers, participantIndexes: indexes, compact: compact)
        var frameBounds = seqGetFragmentFrameBoundsByStep(centers, steps: diagram.steps, participantIndexes: indexes)

        func aggregateFragmentBounds() -> SequenceHorizontalBounds {
            var result = SequenceHorizontalBounds(leftX: 0, rightX: 0)
            for b in frameBounds.values {
                seqExpandHorizontalBounds(&result, leftX: b.leftX, rightX: b.rightX)
            }
            return result
        }

        var fragments = aggregateFragmentBounds()
        let leftOverflow = min(
            groups.reduce(0) { min($0, $1.leftX) },
            min(contentBounds.leftX, min(fragments.leftX, 0))
        )
        if leftOverflow < 0 {
            centers = centers.map { $0 - leftOverflow }
            groups = seqResolveGroupBounds(diagram, centers: centers, participantIndexes: indexes, groupRanges: ranges, compact: compact)
            contentBounds = seqGetDiagramContentBounds(diagram, centers: centers, participantIndexes: indexes, compact: compact)
            frameBounds = seqGetFragmentFrameBoundsByStep(centers, steps: diagram.steps, participantIndexes: indexes)
            fragments = aggregateFragmentBounds()
        }

        let hasGroups = !groups.isEmpty
        let participantLabelHeight = max(
            1,
            diagram.participants.map { seqMermaidLabelLines($0.label).count }.max() ?? 1
        )
        let participantHeaderTopY = hasGroups ? 1 : 0
        let participantHeaderY = participantHeaderTopY
        let participantRuleY = participantHeaderTopY + (compact ? participantLabelHeight - 1 : participantLabelHeight)
        let lifelineStartY = participantRuleY + 1
        let stepStartY = lifelineStartY + 1
        let width = max(
            contentBounds.rightX + 1,
            max(groups.map { $0.rightX + 1 }.max() ?? 0, fragments.rightX + 1)
        )
        let baseHeight = stepStartY + diagram.steps.reduce(0) {
            $0 + seqGetStepHeight($1, centers: centers, participantIndexes: indexes, compact: compact)
        }
        let height = hasGroups ? max(5, baseHeight + 1) : max(3, baseHeight)
        let lifelineEndY = hasGroups ? height - 2 : height - 1

        let participants = diagram.participants.enumerated().map { (index, participant) -> SequenceParticipantPlacement in
            let centerX = centers[index]
            let w = seqParticipantHeaderWidth(participant.label, compact: compact)
            let headerLeftX = centerX - floorDiv(w, 2)
            let labelLines = seqMermaidLabelLines(participant.label)
            return SequenceParticipantPlacement(
                participant: participant,
                centerX: centerX,
                headerLeftX: headerLeftX,
                headerRightX: headerLeftX + w - 1,
                labelLines: labelLines
            )
        }

        var steps: [SequenceStepPlacement] = []
        var activations: [SequenceActivationPlacement] = []
        var activeByParticipant: [String: [(startY: Int, depth: Int)]] = [:]
        var activeParticipantOrder: [String] = []
        var lastEventYByParticipant: [String: Int] = [:]

        func openActivation(_ participant: String, _ y: Int) {
            if activeByParticipant[participant] == nil {
                activeParticipantOrder.append(participant)
            }
            var active = activeByParticipant[participant] ?? []
            active.append((startY: y, depth: active.count))
            activeByParticipant[participant] = active
        }

        func closeActivation(_ participant: String, _ y: Int) {
            guard var active = activeByParticipant[participant],
                  let opened = active.popLast(),
                  let participantIndex = indexes[participant]
            else { return }
            activeByParticipant[participant] = active
            activations.append(SequenceActivationPlacement(
                participant: participant,
                centerX: centers[participantIndex],
                startY: opened.startY,
                endY: y,
                depth: opened.depth
            ))
        }

        var stepY = stepStartY
        var activeFrames: [SequenceActiveFragmentFrame] = []

        for (stepIndex, step) in diagram.steps.enumerated() {
            switch step {
            case .activation(let act):
                let eventY = min(lastEventYByParticipant[act.participant] ?? stepY, lifelineEndY)
                if act.active { openActivation(act.participant, eventY) }
                else { closeActivation(act.participant, eventY) }

            case .note(let note):
                let stepHeight = seqGetStepHeight(step, centers: centers, participantIndexes: indexes, compact: compact)
                let noteIndexes = seqGetParticipantIndexes(indexes, ids: note.over)
                if let lo = noteIndexes.min(), let hi = noteIndexes.max() {
                    let centerX = floorDiv(centers[lo] + centers[hi], 2)
                    let textLines = seqNoteLabelLines(note.label)
                    let w = seqLabelLinesWidth(textLines)
                    let textX: Int
                    if note.position == .left {
                        textX = centerX - w - 2
                    } else if note.position == .right {
                        textX = centerX + 2
                    } else {
                        textX = centerX - floorDiv(w, 2)
                    }
                    steps.append(.note(note: note, textLines: textLines, textX: textX, textY: stepY + 1))
                }
                stepY += stepHeight

            case .fragment(let fragment):
                let stepHeight = seqGetStepHeight(step, centers: centers, participantIndexes: indexes, compact: compact)
                var bounds = frameBounds[stepIndex] ?? seqGetFragmentFrameBounds(centers, fragment: fragment)
                var wallsBefore: SequenceWallPlacement?
                if fragment.kind == .alt || fragment.kind == .loop {
                    if let bounds {
                        activeFrames.append(SequenceActiveFragmentFrame(bounds: bounds, boundaryY: stepY))
                    }
                } else if !activeFrames.isEmpty {
                    let frame = activeFrames[activeFrames.count - 1]
                    bounds = frame.bounds
                    wallsBefore = SequenceWallPlacement(bounds: frame.bounds, startY: frame.boundaryY + 1, endY: stepY - 1)
                    if fragment.kind == .end {
                        activeFrames.removeLast()
                    } else {
                        activeFrames[activeFrames.count - 1].boundaryY = stepY
                    }
                }
                if let bounds {
                    steps.append(.fragment(
                        fragment: fragment,
                        labelText: seqFragmentLabelText(fragment),
                        bounds: bounds,
                        y: stepY,
                        wallsBefore: wallsBefore
                    ))
                }
                stepY += stepHeight

            case .message(let msg):
                guard let fromIndex = indexes[msg.from], let toIndex = indexes[msg.to] else { continue }
                let stepHeight = seqGetStepHeight(step, centers: centers, participantIndexes: indexes, compact: compact)
                let labelLines = seqMermaidLabelLines(seqMessageLabelText(msg))
                if fromIndex == toIndex {
                    let centerX = centers[fromIndex]
                    let bottomY = stepY + labelLines.count + 1
                    steps.append(.selfMessage(
                        message: msg,
                        labelLines: labelLines,
                        centerX: centerX,
                        rightX: centerX + seqSelfMessageLoopWidthForLines(labelLines),
                        topY: stepY,
                        bottomY: bottomY
                    ))
                    if let act = msg.activate { openActivation(act, bottomY) }
                    if let deact = msg.deactivate { closeActivation(deact, bottomY) }
                    lastEventYByParticipant[msg.from] = bottomY
                } else {
                    let fromX = centers[fromIndex]
                    let toX = centers[toIndex]
                    let direction = toX > fromX ? 1 : -1
                    let leftX = min(fromX, toX)
                    let rightX = max(fromX, toX)
                    let inlineLabel = seqInlineMessageLabel(msg, labelLines: labelLines, fromX: fromX, toX: toX, compact: compact)
                    let arrowY = inlineLabel != nil ? stepY : stepY + labelLines.count
                    let renderedLabelWidth = inlineLabel.map(diagramTextWidth) ?? seqLabelLinesWidth(labelLines)
                    let labelX = inlineLabel != nil ? floorDiv(leftX + rightX - renderedLabelWidth, 2) : leftX + 2
                    steps.append(.message(
                        message: msg,
                        labelLines: labelLines,
                        labelX: labelX,
                        labelY: stepY,
                        arrowY: arrowY,
                        fromX: fromX,
                        toX: toX,
                        leftX: leftX,
                        rightX: rightX,
                        headX: seqArrowHeadX(toX, direction: direction, head: msg.head),
                        direction: direction,
                        inlineLabel: inlineLabel
                    ))
                    if let act = msg.activate { openActivation(act, arrowY) }
                    if let deact = msg.deactivate { closeActivation(deact, arrowY) }
                    lastEventYByParticipant[msg.from] = arrowY
                    lastEventYByParticipant[msg.to] = arrowY
                }
                stepY += stepHeight
            }
        }

        for participant in activeParticipantOrder {
            while let active = activeByParticipant[participant], !active.isEmpty {
                closeActivation(participant, lifelineEndY)
            }
        }

        return SequencePlacementPlan(
            width: width,
            height: height,
            rows: SequenceRowsLayout(
                participantHeaderTopY: participantHeaderTopY,
                participantHeaderY: participantHeaderY,
                participantRuleY: participantRuleY,
                lifelineStartY: lifelineStartY,
                lifelineEndY: lifelineEndY
            ),
            participants: participants,
            groups: groups,
            activations: activations,
            steps: steps
        )
    }

    // MARK: - Sequence Render Grid (`sequence/render-grid.ts`)

    // parity: merman/src/sequence/render-grid.ts#SequenceGrid [status=implemented hash=180e724ee1b6]
    public typealias SequenceGrid = DiagramCanvas<SequenceCellStyle, EmptyCanvasMetadata>

    // parity: merman/src/sequence/render-grid.ts#renderSequenceGridText [status=implemented hash=f2542ac64f0f]
    public static func renderSequenceGridText(_ grid: SequenceGrid) -> String {
        grid.toString()
    }

    // parity: merman/src/sequence/render-grid.ts#renderSequenceGridStyledText [status=implemented hash=83c42842eafd]
    public static func renderSequenceGridStyledText(
        _ grid: SequenceGrid,
        colors: ResolvedSequenceStyleColors
    ) -> StyledText {
        renderDiagramGridStyledText(
            grid,
            fg: { run in sequenceStyleColor(run.style, colors: colors) },
            bg: { run in sequenceStyleBackgroundColor(run.style, colors: colors) }
        )
    }

    // MARK: - Sequence Drawing (`sequence/drawing.ts`)

    private static func seqArrowHeadChar(_ head: SequenceArrowHead?, direction: Int) -> String {
        switch head {
        case .open: return direction == 1 ? ">" : "<"
        case .cross: return "✕"
        case .async: return direction == 1 ? ")" : "("
        case nil: return direction == 1 ? "►" : "◄"
        }
    }

    private static func seqSetArrowDepartureFade(
        _ grid: SequenceGrid,
        x: Int,
        y: Int,
        direction: Int,
        style: MessageStyle
    ) {
        let border = BorderChars.rounded
        grid.setCell(x, y, direction == 1 ? border.leftT : border.rightT, style: .fade(style, step: 1))
        for step in 2...5 {
            grid.setCell(x + direction * (step - 1), y, border.horizontal, style: .fade(style, step: step))
        }
    }

    private static func seqRenderParticipantGroups(
        _ grid: SequenceGrid,
        groups: [SequenceGroupPlacement],
        bottomY: Int
    ) {
        let border = BorderChars.rounded
        for bounds in groups {
            if bounds.leftX <= bounds.rightX {
                for x in bounds.leftX...bounds.rightX {
                    grid.setCell(x, 0, border.horizontal, style: .group)
                    grid.setCell(x, bottomY, border.horizontal, style: .group)
                }
            }
            grid.setCell(bounds.leftX, 0, border.topLeft, style: .group)
            grid.setCell(bounds.rightX, 0, border.topRight, style: .group)
            grid.setCell(bounds.leftX, bottomY, border.bottomLeft, style: .group)
            grid.setCell(bounds.rightX, bottomY, border.bottomRight, style: .group)

            if bottomY > 1 {
                for y in 1..<bottomY {
                    for x in [bounds.leftX, bounds.rightX] {
                        let existing = grid.getCell(x, y)?.char
                        if existing == nil || existing == " " || existing == border.vertical {
                            grid.setCell(x, y, border.vertical, style: .group)
                        }
                    }
                }
            }

            if !bounds.labelText.isEmpty {
                grid.setText(max(0, bounds.leftX + 2), 0, bounds.labelText, style: .group)
            }
        }
    }

    private static func seqDrawFragmentWalls(
        _ grid: SequenceGrid,
        bounds: SequenceHorizontalBounds,
        startY: Int,
        endY: Int,
        borderStyle: BorderStyle
    ) {
        guard endY >= startY else { return }
        let border = BorderChars.forStyle(borderStyle)
        for y in startY...endY {
            grid.setCell(bounds.leftX, y, border.vertical, style: .fragment)
            grid.setCell(bounds.rightX, y, border.vertical, style: .fragment)
        }
    }

    private static func seqRenderFragment(
        _ grid: SequenceGrid,
        fragment: SequenceFragment,
        labelText: String,
        bounds: SequenceHorizontalBounds,
        y: Int,
        borderStyle: BorderStyle
    ) {
        let border = BorderChars.forStyle(borderStyle)
        let leftChar: String
        let rightChar: String
        switch fragment.kind {
        case .alt, .loop:
            leftChar = border.topLeft
            rightChar = border.topRight
        case .else:
            leftChar = border.leftT
            rightChar = border.rightT
        case .end:
            leftChar = border.bottomLeft
            rightChar = border.bottomRight
        }
        if bounds.leftX <= bounds.rightX {
            for x in bounds.leftX...bounds.rightX {
                grid.setCell(x, y, border.horizontal, style: .fragment)
            }
        }
        grid.setCell(bounds.leftX, y, leftChar, style: .fragment)
        grid.setCell(bounds.rightX, y, rightChar, style: .fragment)
        if !labelText.isEmpty {
            grid.setText(max(0, bounds.leftX + 2), y, labelText, style: .fragmentLabel)
        }
    }

    // parity: merman/src/sequence/drawing.ts#drawSequenceDiagramGrid [status=implemented hash=32df9e48f6c5]
    public static func drawSequenceDiagramGrid(
        _ diagram: SequenceDiagram,
        options: SequenceDiagramRenderOptions = SequenceDiagramRenderOptions()
    ) throws -> SequenceGrid {
        let plan = createSequencePlacementPlan(diagram, options: options)
        if plan.width == 0 || plan.height == 0 {
            return try SequenceGrid(width: 0, height: 0)
        }
        let border = BorderChars.rounded
        let fragmentBorderStyle = options.fragmentBorderStyle ?? DEFAULT_FRAGMENT_BORDER_STYLE
        let grid = try SequenceGrid(width: plan.width, height: plan.height)

        if !plan.groups.isEmpty {
            seqRenderParticipantGroups(grid, groups: plan.groups, bottomY: plan.height - 1)
        }

        let compact = options.compact ?? false
        for placement in plan.participants {
            let center = placement.centerX
            if compact {
                for (index, line) in placement.labelLines.enumerated() {
                    let start = center - floorDiv(diagramTextWidth(line), 2)
                    grid.setText(max(0, start), plan.rows.participantHeaderY + index, line, style: .participant)
                }
            } else {
                for (index, line) in placement.labelLines.enumerated() {
                    let start = center - floorDiv(diagramTextWidth(line), 2)
                    grid.setText(max(0, start), plan.rows.participantHeaderTopY + index, line, style: .participant)
                }
                if placement.headerLeftX <= placement.headerRightX {
                    for x in placement.headerLeftX...placement.headerRightX {
                        grid.setCell(x, plan.rows.participantRuleY, border.horizontal, style: .participant)
                    }
                }
                grid.setCell(center, plan.rows.participantRuleY, border.topT, style: .participant)
            }

            if plan.rows.lifelineStartY <= plan.rows.lifelineEndY {
                for y in plan.rows.lifelineStartY...plan.rows.lifelineEndY {
                    let distance = y - plan.rows.lifelineStartY
                    let style: SequenceCellStyle = (!compact && distance < 3) ? .lifelineRamp(distance + 1) : .lifeline
                    grid.setCell(center, y, border.vertical, style: style)
                }
            }
        }

        for placement in plan.steps {
            switch placement {
            case .note(_, let textLines, let textX, let textY):
                for (index, line) in textLines.enumerated() {
                    grid.setText(max(0, textX), textY + index, line, style: .noteBadge)
                }

            case .fragment(let fragment, let labelText, let bounds, let y, let wallsBefore):
                if let walls = wallsBefore {
                    seqDrawFragmentWalls(grid, bounds: walls.bounds, startY: walls.startY, endY: walls.endY, borderStyle: fragmentBorderStyle)
                }
                seqRenderFragment(grid, fragment: fragment, labelText: labelText, bounds: bounds, y: y, borderStyle: fragmentBorderStyle)

            case .selfMessage(let message, let labelLines, let centerX, let rightX, let topRow, let bottomRow):
                let msgStyle: MessageStyle = message.style == .dashed ? .response : .request
                let cellStyle = SequenceCellStyle.fromMessageStyle(msgStyle)
                seqSetArrowDepartureFade(grid, x: centerX, y: topRow, direction: 1, style: msgStyle)
                if centerX + SEQUENCE_FADE_STEPS.count < rightX {
                    for x in (centerX + SEQUENCE_FADE_STEPS.count)..<rightX {
                        grid.setCell(x, topRow, border.horizontal, style: cellStyle)
                    }
                }
                grid.setCell(rightX, topRow, border.topRight, style: cellStyle)
                for (lineIndex, line) in labelLines.enumerated() {
                    let y = topRow + lineIndex + 1
                    grid.setCell(centerX, y, border.vertical, style: .lifeline)
                    grid.setText(max(0, centerX + 2), y, line, style: cellStyle)
                    grid.setCell(rightX, y, border.vertical, style: cellStyle)
                }
                if centerX + 1 < rightX {
                    for x in (centerX + 1)..<rightX {
                        grid.setCell(x, bottomRow, border.horizontal, style: cellStyle)
                    }
                }
                let headX = message.head == nil ? centerX : centerX + 1
                grid.setCell(headX, bottomRow, seqArrowHeadChar(message.head, direction: -1), style: cellStyle)
                grid.setCell(rightX, bottomRow, border.bottomRight, style: cellStyle)

            case .message(let message, let labelLines, let labelX, let labelY, let arrowY, let fromX, _, let leftX, let rightX, let headX, let direction, let inlineLabel):
                let msgStyle: MessageStyle = message.style == .dashed ? .response : .request
                let cellStyle = SequenceCellStyle.fromMessageStyle(msgStyle)
                if inlineLabel == nil {
                    for (lineIndex, line) in labelLines.enumerated() {
                        grid.setText(max(0, labelX), labelY + lineIndex, line, style: cellStyle)
                    }
                }
                if leftX + 1 < rightX {
                    for x in (leftX + 1)..<rightX {
                        grid.setCell(x, arrowY, border.horizontal, style: cellStyle)
                    }
                }
                seqSetArrowDepartureFade(grid, x: fromX, y: arrowY, direction: direction, style: msgStyle)
                grid.setCell(headX, arrowY, seqArrowHeadChar(message.head, direction: direction), style: cellStyle)
                if let inlineLabel {
                    grid.setText(max(0, labelX), labelY, inlineLabel, style: cellStyle)
                }
            }
        }

        for activation in plan.activations {
            guard activation.startY <= activation.endY else { continue }
            for y in activation.startY...activation.endY {
                if grid.getCell(activation.centerX, y)?.char == border.vertical {
                    grid.setCell(activation.centerX, y, "┃", style: .lifeline)
                }
            }
        }

        return grid
    }

    // MARK: - Sequence Diagram (`sequence/diagram.ts`)

    // parity: merman/src/sequence/diagram.ts#renderSequenceDiagram [status=implemented hash=1b35e235f36e]
    public static func renderSequenceDiagram(
        _ content: String,
        options: SequenceDiagramRenderOptions = SequenceDiagramRenderOptions()
    ) throws -> String {
        renderSequenceGridText(try drawSequenceDiagramGrid(try parseMermaidSequenceDiagram(content), options: options))
    }
}

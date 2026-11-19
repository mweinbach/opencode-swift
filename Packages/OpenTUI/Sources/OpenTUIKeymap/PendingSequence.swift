// Pure Swift 6 port of keymap/src/services/pending-sequence.ts.

public struct PendingSequencePatternCapture: Equatable, Sendable {
    public let name: String
    public let payloadKey: String
    public let values: [KeymapValue]
    public let parts: [KeySequencePart]

    public init(
        name: String,
        payloadKey: String,
        values: [KeymapValue],
        parts: [KeySequencePart]
    ) {
        self.name = name
        self.payloadKey = payloadKey
        self.values = values
        self.parts = parts
    }
}

public struct PendingSequenceCapture<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let layer: RegisteredLayer<Target, Event>
    public let binding: BindingState<Target, Event>
    public let index: Int
    public let parts: [KeySequencePart]
    public let patterns: [PendingSequencePatternCapture]?

    public init(
        layer: RegisteredLayer<Target, Event>,
        binding: BindingState<Target, Event>,
        index: Int,
        parts: [KeySequencePart],
        patterns: [PendingSequencePatternCapture]? = nil
    ) {
        self.layer = layer
        self.binding = binding
        self.index = index
        self.parts = parts
        self.patterns = patterns
    }
}

public struct PendingSequenceState<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let captures: [PendingSequenceCapture<Target, Event>]

    public init(captures: [PendingSequenceCapture<Target, Event>]) {
        self.captures = captures
    }
}

// parity: keymap/src/services/pending-sequence.ts#isSamePendingSequence [status=implemented hash=833d21a25c70]
public func isSamePendingSequence<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ current: PendingSequenceState<Target, Event>?,
    _ next: PendingSequenceState<Target, Event>?
) -> Bool {
    if current == nil && next == nil {
        return true
    }

    guard let current, let next else {
        return false
    }

    if current.captures.count != next.captures.count {
        return false
    }

    for index in 0..<current.captures.count {
        let left = current.captures[index]
        let right = next.captures[index]
        if left.layer !== right.layer
            || left.binding !== right.binding
            || left.index != right.index
            || left.parts.count != right.parts.count
        {
            return false
        }

        for partIndex in 0..<left.parts.count {
            if left.parts[partIndex].match != right.parts[partIndex].match {
                return false
            }
        }

        let leftPatterns = left.patterns ?? []
        let rightPatterns = right.patterns ?? []
        if leftPatterns.count != rightPatterns.count {
            return false
        }

        for patternIndex in 0..<leftPatterns.count {
            let leftPattern = leftPatterns[patternIndex]
            let rightPattern = rightPatterns[patternIndex]
            if leftPattern.name != rightPattern.name
                || leftPattern.values.count != rightPattern.values.count
            {
                return false
            }

            for valueIndex in 0..<leftPattern.values.count {
                if leftPattern.values[valueIndex] != rightPattern.values[valueIndex] {
                    return false
                }
            }
        }
    }

    return true
}

// parity: keymap/src/services/pending-sequence.ts#popCapture [status=implemented hash=5fc82fb31992]
public func popCapture<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ capture: PendingSequenceCapture<Target, Event>
) -> PendingSequenceCapture<Target, Event>? {
    guard let lastPart = capture.parts.last, capture.parts.count > 1 else {
        return nil
    }

    var index = capture.index - 1
    var patterns = capture.patterns
    if let patternName = lastPart.patternName,
        let existingPatterns = patterns,
        let lastPattern = existingPatterns.last,
        lastPattern.name == patternName
    {
        if lastPattern.values.count > 1 {
            index = capture.index
            var updated = Array(existingPatterns.dropLast())
            updated.append(
                PendingSequencePatternCapture(
                    name: lastPattern.name,
                    payloadKey: lastPattern.payloadKey,
                    values: Array(lastPattern.values.dropLast()),
                    parts: Array(lastPattern.parts.dropLast())
                )
            )
            patterns = updated
        } else {
            patterns = Array(existingPatterns.dropLast())
        }
    }

    return PendingSequenceCapture(
        layer: capture.layer,
        binding: capture.binding,
        index: index,
        parts: Array(capture.parts.dropLast()),
        patterns: patterns
    )
}

// parity: keymap/src/services/pending-sequence.ts#collectSequencePartsFromPending [status=implemented hash=9b630f18e217]
public func collectSequencePartsFromPending<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ pending: PendingSequenceState<Target, Event>
) -> [KeySequencePart] {
    guard let firstCapture = pending.captures.first, !firstCapture.parts.isEmpty else {
        return []
    }

    var parts: [KeySequencePart] = []
    parts.reserveCapacity(firstCapture.parts.count)

    for index in 0..<firstCapture.parts.count {
        let firstPart = firstCapture.parts[index]
        var display: String?
        var tokenName: String?
        var hasDisplayConflict = false
        var hasTokenConflict = false

        for capture in pending.captures {
            guard index < capture.parts.count else {
                continue
            }
            let part = capture.parts[index]

            if display == nil {
                display = part.display
                tokenName = part.tokenName
                continue
            }

            if !hasDisplayConflict && display != part.display {
                hasDisplayConflict = true
            }

            if !hasTokenConflict && tokenName != part.tokenName {
                hasTokenConflict = true
            }
        }

        let resolvedDisplay: String
        if let existingDisplay = display, !hasDisplayConflict {
            resolvedDisplay = existingDisplay
        } else {
            resolvedDisplay =
                (try? stringifyKeyStroke(.stroke(firstPart.stroke.asStrokeInput))) ?? firstPart.stroke.name
        }

        let resolvedToken = hasTokenConflict ? nil : tokenName
        if let created = try? createKeySequencePart(
            firstPart.stroke.asStrokeInput,
            display: resolvedDisplay,
            match: firstPart.match,
            tokenName: resolvedToken
        ) {
            parts.append(created)
        } else {
            parts.append(
                KeySequencePart(
                    stroke: cloneKeyStroke(firstPart.stroke),
                    display: resolvedDisplay,
                    match: firstPart.match,
                    tokenName: resolvedToken
                )
            )
        }
    }

    return parts
}

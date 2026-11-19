// Pure Swift 6 port of keymap/src/services/sequence-index.ts and services/primitives/pending-captures.ts.

// MARK: - Pending Capture Primitives

// parity: keymap/src/services/primitives/pending-captures.ts#patternCaptureCount [status=implemented hash=c4c18fc7384e]
public func patternCaptureCount<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ capture: PendingSequenceCapture<Target, Event>
) -> Int {
    guard capture.index >= 0, capture.index < capture.binding.sequence.count else {
        return 0
    }
    let part = capture.binding.sequence[capture.index]
    guard let patternName = part.patternName else {
        return 0
    }
    guard let captured = capture.patterns?.last, captured.name == patternName else {
        return 0
    }
    return captured.values.count
}

// parity: keymap/src/services/primitives/pending-captures.ts#captureHasMinimum [status=implemented hash=a102c1c54eaf]
public func captureHasMinimum<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ capture: PendingSequenceCapture<Target, Event>,
    patterns: [String: ResolvedSequencePattern<Event>],
    missingPatternResult: Bool = true
) -> Bool {
    guard capture.index >= 0, capture.index < capture.binding.sequence.count else {
        return true
    }
    let part = capture.binding.sequence[capture.index]
    guard let patternName = part.patternName else {
        return true
    }
    guard let pattern = patterns[patternName] else {
        return missingPatternResult
    }
    return patternCaptureCount(capture) >= pattern.min
}

// parity: keymap/src/services/primitives/pending-captures.ts#captureHasContinuations [status=implemented hash=6d79d5320cf2]
public func captureHasContinuations<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ capture: PendingSequenceCapture<Target, Event>,
    patterns: [String: ResolvedSequencePattern<Event>],
    missingPatternMinimum: Bool = true
) -> Bool {
    if capture.index >= 0, capture.index < capture.binding.sequence.count {
        let part = capture.binding.sequence[capture.index]
        if let patternName = part.patternName,
            let pattern = patterns[patternName],
            patternCaptureCount(capture) < pattern.max
        {
            return true
        }
    }
    return captureHasMinimum(capture, patterns: patterns, missingPatternResult: missingPatternMinimum)
        && (capture.index + 1 < capture.binding.sequence.count)
}

// parity: keymap/src/services/primitives/pending-captures.ts#captureIsExact [status=implemented hash=a9e2b9574345]
public func captureIsExact<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ capture: PendingSequenceCapture<Target, Event>,
    patterns: [String: ResolvedSequencePattern<Event>]
) -> Bool {
    capture.index == capture.binding.sequence.count - 1
        && captureHasMinimum(capture, patterns: patterns, missingPatternResult: false)
}

// MARK: - Sequence Trie Types

// parity: keymap/src/services/sequence-index.ts#SequenceActiveOption [status=implemented hash=6ffd2315eb6e]
public struct SequenceActiveOption<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let part: KeySequencePart
    public let binding: BindingState<Target, Event>
    public let index: Int
    public let exact: Bool
    public let continues: Bool

    public init(
        part: KeySequencePart,
        binding: BindingState<Target, Event>,
        index: Int,
        exact: Bool,
        continues: Bool
    ) {
        self.part = part
        self.binding = binding
        self.index = index
        self.exact = exact
        self.continues = continues
    }
}

public struct SequenceNodePresentation: Equatable, Hashable, Sendable {
    public let display: String
    public let tokenName: String?

    public init(display: String, tokenName: String? = nil) {
        self.display = display
        self.tokenName = tokenName
    }
}

/// Prefix trie node indexing key sequences and dynamic pattern segments.
public final class SequenceNode<Target: Hashable & Sendable, Event: KeymapEvent>: @unchecked Sendable {
    public weak var parent: SequenceNode<Target, Event>?
    public let depth: Int
    public let stroke: NormalizedKeyStroke?
    public let match: KeyMatch?
    public let pattern: ResolvedSequencePattern<Event>?
    public var children: [KeyMatch: SequenceNode<Target, Event>] = [:]
    internal var childKeyOrder: [KeyMatch] = []
    public var patternChildren: [SequenceNode<Target, Event>] = []
    public var bindings: [BindingState<Target, Event>] = []
    public var reachableBindings: [BindingState<Target, Event>] = []

    public init(
        parent: SequenceNode<Target, Event>?,
        stroke: NormalizedKeyStroke?,
        match: KeyMatch?,
        pattern: ResolvedSequencePattern<Event>? = nil
    ) {
        self.parent = parent
        self.depth = parent.map { $0.depth + 1 } ?? 0
        self.stroke = stroke
        self.match = match
        self.pattern = pattern
    }

    public func setChild(_ child: SequenceNode<Target, Event>, forMatch match: KeyMatch) {
        if children[match] == nil {
            childKeyOrder.append(match)
        }
        children[match] = child
    }
}

// MARK: - Sequence Index Operations

// parity: keymap/src/services/sequence-index.ts#createSequenceNode [status=implemented hash=8a37aba41f96]
public func createSequenceNode<Target: Hashable & Sendable, Event: KeymapEvent>(
    parent: SequenceNode<Target, Event>?,
    stroke: NormalizedKeyStroke?,
    match: KeyMatch?,
    pattern: ResolvedSequencePattern<Event>? = nil
) -> SequenceNode<Target, Event> {
    SequenceNode(parent: parent, stroke: stroke, match: match, pattern: pattern)
}

// parity: keymap/src/services/sequence-index.ts#buildSequenceTree [status=implemented hash=3ee001dabf45]
public func buildSequenceTree<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ bindings: [BindingState<Target, Event>],
    patterns: [String: ResolvedSequencePattern<Event>] = [:]
) -> SequenceNode<Target, Event> {
    let root: SequenceNode<Target, Event> = createSequenceNode(parent: nil, stroke: nil, match: nil)
    for binding in bindings {
        if binding.event != .press {
            continue
        }

        var node = root
        for part in binding.sequence {
            let child: SequenceNode<Target, Event>
            if let patternName = part.patternName {
                let pattern = patterns[patternName]
                if let existing = node.patternChildren.first(where: { $0.pattern?.name == patternName }) {
                    child = existing
                } else {
                    let created: SequenceNode<Target, Event> = createSequenceNode(
                        parent: node,
                        stroke: part.stroke,
                        match: part.match,
                        pattern: pattern
                    )
                    node.patternChildren.append(created)
                    child = created
                }
            } else {
                if let existing = node.children[part.match] {
                    child = existing
                } else {
                    let created: SequenceNode<Target, Event> = createSequenceNode(
                        parent: node,
                        stroke: part.stroke,
                        match: part.match
                    )
                    node.setChild(created, forMatch: part.match)
                    child = created
                }
            }

            child.reachableBindings.append(binding)
            node = child
        }

        node.bindings.append(binding)
    }

    return root
}

// parity: keymap/src/services/sequence-index.ts#getCaptureNode [status=implemented hash=3a25b81377a0]
public func getCaptureNode<Target: Hashable & Sendable, Event: KeymapEvent>(
    root: SequenceNode<Target, Event>,
    capture: PendingSequenceCapture<Target, Event>
) -> SequenceNode<Target, Event>? {
    guard capture.index >= 0 else {
        return nil
    }
    var node: SequenceNode<Target, Event>? = root
    for index in 0...capture.index {
        guard index < capture.binding.sequence.count, let current = node else {
            return nil
        }
        let part = capture.binding.sequence[index]
        if let patternName = part.patternName {
            node = current.patternChildren.first(where: { $0.pattern?.name == patternName })
        } else {
            node = current.children[part.match]
        }
    }
    return node
}

// parity: keymap/src/services/sequence-index.ts#getNodeSequence [status=implemented hash=ba5b30858d1e]
public func getNodeSequence<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ node: SequenceNode<Target, Event>
) -> [KeySequencePart] {
    var parts: [KeySequencePart] = []
    var current: SequenceNode<Target, Event>? = node

    while let active = current, let stroke = active.stroke, let match = active.match {
        parts.append(
            KeySequencePart(
                stroke: cloneKeyStroke(stroke),
                display: "",
                match: match
            )
        )
        current = active.parent
    }

    parts.reverse()
    return parts
}

// parity: keymap/src/services/sequence-index.ts#getNodePresentation [status=implemented hash=9a7f79f02127]
public func getNodePresentation<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ node: SequenceNode<Target, Event>
) -> SequenceNodePresentation {
    guard let stroke = node.stroke, node.depth > 0 else {
        return SequenceNodePresentation(display: "")
    }

    let partIndex = node.depth - 1
    for binding in node.reachableBindings {
        if partIndex < binding.sequence.count {
            let part = binding.sequence[partIndex]
            return SequenceNodePresentation(display: part.display, tokenName: part.tokenName)
        }
    }

    let rendered = (try? stringifyKeyStroke(.stroke(stroke.asStrokeInput))) ?? stroke.name
    return SequenceNodePresentation(display: rendered)
}

// parity: keymap/src/services/sequence-index.ts#firstNodeForMatch [status=implemented hash=226897f5df4d]
public func firstNodeForMatch<Target: Hashable & Sendable, Event: KeymapEvent>(
    root: SequenceNode<Target, Event>,
    match: KeyMatch
) -> SequenceNode<Target, Event>? {
    if let direct = root.children[match] {
        return direct
    }
    return root.patternChildren.first(where: { $0.match == match })
}

// parity: keymap/src/services/sequence-index.ts#childNodes [status=implemented hash=a73845888271]
public func childNodes<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ node: SequenceNode<Target, Event>
) -> [SequenceNode<Target, Event>] {
    var result: [SequenceNode<Target, Event>] = []
    result.reserveCapacity(node.children.count + node.patternChildren.count)
    var seen: Set<KeyMatch> = []
    for key in node.childKeyOrder {
        if let child = node.children[key] {
            result.append(child)
            seen.insert(key)
        }
    }
    if seen.count < node.children.count {
        for key in node.children.keys.sorted() where !seen.contains(key) {
            if let child = node.children[key] {
                result.append(child)
            }
        }
    }
    result.append(contentsOf: node.patternChildren)
    return result
}

// parity: keymap/src/services/sequence-index.ts#activeOptionsForBindings [status=implemented hash=606246a5a782]
public func activeOptionsForBindings<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ bindings: [BindingState<Target, Event>]
) -> [SequenceActiveOption<Target, Event>] {
    var options: [SequenceActiveOption<Target, Event>] = []
    for binding in bindings {
        if let part = binding.sequence.first {
            options.append(
                SequenceActiveOption(
                    part: part,
                    binding: binding,
                    index: 0,
                    exact: binding.sequence.count == 1,
                    continues: binding.sequence.count > 1
                )
            )
        }
    }
    return options
}

// parity: keymap/src/services/sequence-index.ts#activeOptionsForCaptures [status=implemented hash=32f5abf61a7a]
public func activeOptionsForCaptures<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ captures: [PendingSequenceCapture<Target, Event>],
    patterns: [String: ResolvedSequencePattern<Event>] = [:]
) -> [SequenceActiveOption<Target, Event>] {
    var options: [SequenceActiveOption<Target, Event>] = []
    for capture in captures {
        if !captureHasMinimum(capture, patterns: patterns) {
            continue
        }
        let index = capture.index + 1
        if index < capture.binding.sequence.count {
            let part = capture.binding.sequence[index]
            options.append(
                SequenceActiveOption(
                    part: part,
                    binding: capture.binding,
                    index: index,
                    exact: index == capture.binding.sequence.count - 1,
                    continues: index < capture.binding.sequence.count - 1
                )
            )
        }
    }
    return options
}

private func appendPatternCapture<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ capture: PendingSequenceCapture<Target, Event>,
    index: Int,
    part: KeySequencePart,
    value: KeymapValue
) -> PendingSequenceCapture<Target, Event> {
    guard let patternName = part.patternName else {
        return PendingSequenceCapture(
            layer: capture.layer,
            binding: capture.binding,
            index: index,
            parts: capture.parts,
            patterns: capture.patterns
        )
    }

    var patterns = capture.patterns ?? []
    if let last = patterns.last, last.name == patternName {
        patterns[patterns.count - 1] = PendingSequencePatternCapture(
            name: last.name,
            payloadKey: last.payloadKey,
            values: last.values + [value],
            parts: last.parts + [part]
        )
    } else {
        patterns.append(
            PendingSequencePatternCapture(
                name: patternName,
                payloadKey: part.payloadKey ?? patternName,
                values: [value],
                parts: [part]
            )
        )
    }

    return PendingSequenceCapture(
        layer: capture.layer,
        binding: capture.binding,
        index: index,
        parts: capture.parts + [part],
        patterns: patterns
    )
}

// parity: keymap/src/services/sequence-index.ts#capturePriority [status=implemented hash=48abc546068a]
public func capturePriority<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ capture: PendingSequenceCapture<Target, Event>,
    matchKeys: [KeyMatch]
) -> Int {
    guard let part = capture.parts.last, part.patternName == nil else {
        return matchKeys.count
    }
    return matchKeys.firstIndex(of: part.match) ?? matchKeys.count
}

// parity: keymap/src/services/sequence-index.ts#advanceSequenceBinding [status=implemented hash=7d22bbb260f1]
public func advanceSequenceBinding<Target: Hashable & Sendable, Event: KeymapEvent>(
    layer: RegisteredLayer<Target, Event>,
    binding: BindingState<Target, Event>,
    index: Int,
    parts: [KeySequencePart],
    patterns: [PendingSequencePatternCapture]?,
    matchKeys: [KeyMatch],
    event: Event,
    matchPattern: (String, Event) -> SequencePatternMatch?,
    createPatternPart: (Event, String, SequencePatternMatch) -> KeySequencePart
) -> PendingSequenceCapture<Target, Event>? {
    guard index >= 0, index < binding.sequence.count else {
        return nil
    }
    let part = binding.sequence[index]

    if let patternName = part.patternName {
        guard let patternMatch = matchPattern(patternName, event) else {
            return nil
        }
        let eventPart = createPatternPart(event, patternName, patternMatch)
        return appendPatternCapture(
            PendingSequenceCapture(
                layer: layer,
                binding: binding,
                index: index,
                parts: parts,
                patterns: patterns
            ),
            index: index,
            part: eventPart,
            value: patternMatch.value ?? .string(event.name)
        )
    }

    if !matchKeys.contains(part.match) {
        return nil
    }

    return PendingSequenceCapture(
        layer: layer,
        binding: binding,
        index: index,
        parts: parts + [part],
        patterns: patterns
    )
}

// parity: keymap/src/services/sequence-index.ts#advanceSequenceCapture [status=implemented hash=991363628504]
public func advanceSequenceCapture<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ capture: PendingSequenceCapture<Target, Event>,
    matchKeys: [KeyMatch],
    event: Event,
    patterns: [String: ResolvedSequencePattern<Event>],
    matchPattern: (String, Event) -> SequencePatternMatch?,
    createPatternPart: (Event, String, SequencePatternMatch) -> KeySequencePart
) -> PendingSequenceCapture<Target, Event>? {
    if capture.index >= 0, capture.index < capture.binding.sequence.count {
        let currentPart = capture.binding.sequence[capture.index]
        if let patternName = currentPart.patternName {
            if let pattern = patterns[patternName],
                patternCaptureCount(capture) < pattern.max,
                let patternMatch = matchPattern(pattern.name, event)
            {
                let part = createPatternPart(event, pattern.name, patternMatch)
                return appendPatternCapture(
                    capture,
                    index: capture.index,
                    part: part,
                    value: patternMatch.value ?? .string(event.name)
                )
            }

            if !captureHasMinimum(capture, patterns: patterns, missingPatternResult: false) {
                return nil
            }

            return advanceSequenceBinding(
                layer: capture.layer,
                binding: capture.binding,
                index: capture.index + 1,
                parts: capture.parts,
                patterns: capture.patterns,
                matchKeys: matchKeys,
                event: event,
                matchPattern: matchPattern,
                createPatternPart: createPatternPart
            )
        }
    }

    return advanceSequenceBinding(
        layer: capture.layer,
        binding: capture.binding,
        index: capture.index + 1,
        parts: capture.parts,
        patterns: capture.patterns,
        matchKeys: matchKeys,
        event: event,
        matchPattern: matchPattern,
        createPatternPart: createPatternPart
    )
}

// parity: keymap/src/services/sequence-index.ts#collectRootSequenceCaptures [status=implemented hash=2a7d33d7d1d3]
public func collectRootSequenceCaptures<Target: Hashable & Sendable, Event: KeymapEvent>(
    layer: RegisteredLayer<Target, Event>,
    matchKeys: [KeyMatch],
    event: Event,
    matchPattern: (String, Event) -> SequencePatternMatch?,
    createPatternPart: (Event, String, SequencePatternMatch) -> KeySequencePart
) -> [PendingSequenceCapture<Target, Event>] {
    var captures: [PendingSequenceCapture<Target, Event>] = []
    var bestPriority = Int.max

    for binding in layer.bindings {
        if binding.event != .press {
            continue
        }

        guard
            let capture = advanceSequenceBinding(
                layer: layer,
                binding: binding,
                index: 0,
                parts: [],
                patterns: nil,
                matchKeys: matchKeys,
                event: event,
                matchPattern: matchPattern,
                createPatternPart: createPatternPart
            )
        else {
            continue
        }

        let priority = capturePriority(capture, matchKeys: matchKeys)
        if priority < bestPriority {
            bestPriority = priority
            captures.removeAll(keepingCapacity: true)
        }

        if priority == bestPriority {
            captures.append(capture)
        }
    }

    return captures
}

public enum SessionTurn {
    public struct Time: Equatable, Hashable, Sendable, Codable {
        public let created: Double
        public let firstToken: Double?
        public let streamed: Double?
        public let completed: Double?

        public init(
            created: Double,
            firstToken: Double? = nil,
            streamed: Double? = nil,
            completed: Double? = nil
        ) {
            self.created = created
            self.firstToken = firstToken
            self.streamed = streamed
            self.completed = completed
        }
    }

    public struct Tokens: Equatable, Hashable, Sendable, Codable {
        public let output: Double
        public let reasoning: Double

        public init(output: Double, reasoning: Double) {
            self.output = output
            self.reasoning = reasoning
        }
    }

    // parity: util/src/session-turn.ts#Message [status=implemented hash=3a82d99d5d27]
    public struct Message: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let type: String
        public let time: Time
        public let tokens: Tokens?

        public init(id: String, type: String, time: Time, tokens: Tokens? = nil) {
            self.id = id
            self.type = type
            self.time = time
            self.tokens = tokens
        }
    }

    // parity: util/src/session-turn.ts#Options [status=implemented hash=f9413c78cfcb]
    public struct Options: Equatable, Hashable, Sendable, Codable {
        public let index: Int?
        public let legacy: Bool?

        public init(index: Int? = nil, legacy: Bool? = nil) {
            self.index = index
            self.legacy = legacy
        }
    }

    /// Milliseconds from the prompt that started the turn until `message` completed, or `0` while it runs.
    // parity: util/src/session-turn.ts#duration [status=implemented hash=84e6c34c7bbc]
    public static func duration(
        _ messages: [Message],
        message: Message,
        options: Options = Options()
    ) -> Double {
        guard let completed = message.time.completed else { return 0 }
        let idx = options.index ?? (messages.firstIndex { $0.id == message.id } ?? -1)
        let end = idx == -1 ? messages.count : idx
        let isLegacy = options.legacy ?? legacy(messages)
        let inputIdx = inputIndex(messages: messages, end: end, legacy: isLegacy)
        let startCreated = (inputIdx >= 0 && inputIdx < messages.count)
            ? messages[inputIdx].time.created
            : message.time.created
        return max(0, completed - startCreated)
    }

    /// Output and reasoning tokens per second while the provider streamed them, or `nil` until every step has streamed.
    // parity: util/src/session-turn.ts#tokensPerSecond [status=implemented hash=9750cd17b945]
    public static func tokensPerSecond(
        _ messages: [Message],
        message: Message,
        options: Options = Options()
    ) -> Double? {
        let steps = turnSteps(messages: messages, message: message, options: options)
        var durations: [Double] = []
        durations.reserveCapacity(steps.count)
        for step in steps {
            guard let streamed = step.time.streamed else { continue }
            durations.append(max(0, streamed - (step.time.firstToken ?? step.time.created)))
        }
        guard !steps.isEmpty && durations.count == steps.count else { return nil }
        let output = steps.reduce(0.0) { $0 + ($1.tokens?.output ?? 0) + ($1.tokens?.reasoning ?? 0) }
        let total = durations.reduce(0.0, +)
        guard output > 0 && total > 0 else { return nil }
        return output / (total / 1_000.0)
    }

    // parity: util/src/session-turn.ts#legacy [status=implemented hash=310709db9918]
    public static func legacy(_ messages: [Message]) -> Bool {
        !messages.contains { $0.type == "idle" }
    }

    private static func turnSteps(messages: [Message], message: Message, options: Options) -> [Message] {
        let idx = options.index ?? (messages.firstIndex { $0.id == message.id } ?? -1)
        let end = idx == -1 ? messages.count : min(messages.count, idx + 1)
        let isLegacy = options.legacy ?? legacy(messages)
        let start = inputIndex(messages: messages, end: end, legacy: isLegacy)
        let sliceStart = max(0, start + 1)
        guard sliceStart < end else { return [] }
        return messages[sliceStart..<end].filter { $0.type == "assistant" }
    }

    private static func inputIndex(messages: [Message], end: Int, legacy: Bool) -> Int {
        var input = -1
        let upper = min(end, messages.count) - 1
        if upper < 0 { return -1 }
        for index in stride(from: upper, through: 0, by: -1) {
            let msg = messages[index]
            if msg.type == "idle" { return input }
            if msg.type != "user" && msg.type != "synthetic" { continue }
            if legacy { return index }
            input = index
        }
        return input
    }
}

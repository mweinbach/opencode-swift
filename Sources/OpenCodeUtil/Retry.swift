/// Protocol for errors carrying a structured network/system error code and optional cause chain.
public protocol CausalError: Error {
    var errorCode: String? { get }
    var underlyingCause: (any Error)? { get }
}

public extension CausalError {
    var errorCode: String? { nil }
    var underlyingCause: (any Error)? { nil }
}

/// Configuration for exponential-backoff retries matching `util/src/retry.ts`.
// parity: util/src/retry.ts#RetryOptions [status=implemented hash=af06d619b161]
public struct RetryOptions: Sendable {
    public let attempts: Int
    public let delay: Int
    public let factor: Double
    public let maxDelay: Int
    public let retryIf: (@Sendable (any Error) -> Bool)?

    public init(
        attempts: Int = 3,
        delay: Int = 500,
        factor: Double = 2,
        maxDelay: Int = 10_000,
        retryIf: (@Sendable (any Error) -> Bool)? = nil
    ) {
        self.attempts = attempts
        self.delay = delay
        self.factor = factor
        self.maxDelay = maxDelay
        self.retryIf = retryIf
    }
}

private let transientErrorMessages: [String] = [
    "load failed",
    "network connection was lost",
    "network request failed",
    "failed to fetch",
    "econnreset",
    "econnrefused",
    "epipe",
    "etimedout",
    "socket hang up",
]

/// Checks whether `error` (or any cause up to depth 5) indicates a transient transport failure.
public func isTransientError(_ error: (any Error)?, depth: Int = 0) -> Bool {
    guard let error else { return false }
    let code: String
    if let causal = error as? any CausalError, let c = causal.errorCode {
        code = c
    } else {
        code = ""
    }
    let message = "\(String(describing: error)) \(code)".lowercased()
    for needle in transientErrorMessages where message.contains(needle) {
        return true
    }
    guard depth < 5, let causal = error as? any CausalError, let cause = causal.underlyingCause else {
        return false
    }
    return isTransientError(cause, depth: depth + 1)
}

/// Retries an async operation with exponential backoff matching `util/src/retry.ts`.
// parity: util/src/retry.ts#retry [status=implemented hash=90375e6855b4]
public func retry<T: Sendable>(
    options: RetryOptions = RetryOptions(),
    sleep: (@Sendable (Int) async throws -> Void)? = nil,
    operation: @Sendable () async throws -> T
) async throws -> T {
    let attempts = max(1, options.attempts)
    let retryIf: @Sendable (any Error) -> Bool = options.retryIf ?? { isTransientError($0) }
    var lastError: (any Error)?

    for attempt in 0..<attempts {
        do {
            return try await operation()
        } catch {
            lastError = error
            if attempt == attempts - 1 || !retryIf(error) {
                throw error
            }
            var factorPower = 1.0
            for _ in 0..<attempt {
                factorPower *= options.factor
            }
            let delayMs = min(Int((Double(options.delay) * factorPower).rounded(.towardZero)), options.maxDelay)
            if let sleep {
                try await sleep(delayMs)
            } else {
                try await Task.sleep(for: .milliseconds(max(0, delayMs)))
            }
        }
    }
    throw lastError!
}

/// Pure-Swift range-reduced exponential function (`exp(x)`) accurate to ~1e-15
/// without importing `Darwin`, `Glibc`, `Musl`, `WinSDK`, or `Foundation`.
internal func pureExp(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    if x >= 709.782712893384 { return .infinity }
    if x <= -745.1332191019412 { return 0.0 }
    if x == 0.0 { return 1.0 }

    // Cody-Waite range reduction: x = k * ln(2) + r, with |r| <= ln(2) / 2.
    let ln2 = 0.693147180559945309417232121458176568
    let ln2Hi = 0.693147180369123816490
    let ln2Lo = 1.90821492927058770002e-10

    let k = Int((x / ln2).rounded(.toNearestOrEven))
    let r = (x - Double(k) * ln2Hi) - Double(k) * ln2Lo

    // Taylor polynomial of degree 18 on |r| <= 0.3466 (error < 1e-23).
    var sum = 1.0
    var term = 1.0
    for n in 1...18 {
        term *= r / Double(n)
        sum += term
    }

    // Scale by 2^k using exact IEEE-754 power-of-two construction.
    if k < -1022 {
        let scale1 = Double(sign: .plus, exponent: -1022, significand: 1.0)
        let scale2 = Double(sign: .plus, exponent: k + 1022, significand: 1.0)
        return (sum * scale1) * scale2
    } else if k > 1023 {
        let scale1 = Double(sign: .plus, exponent: 1023, significand: 1.0)
        let scale2 = Double(sign: .plus, exponent: k - 1023, significand: 1.0)
        return (sum * scale1) * scale2
    } else {
        return sum * Double(sign: .plus, exponent: k, significand: 1.0)
    }
}

// MARK: - Scroll Acceleration

// parity: core/src/lib/scroll-acceleration.ts#ScrollAcceleration [status=implemented hash=4fdd1bc990d0]
public protocol ScrollAcceleration: Sendable {
    mutating func tick(now: Double) -> Double
    mutating func reset()
}

// parity: core/src/lib/scroll-acceleration.ts#LinearScrollAccel [status=implemented hash=d4340030a813]
public struct LinearScrollAccel: ScrollAcceleration, Equatable, Hashable, Sendable {
    public init() {}

    // parity: core/src/lib/scroll-acceleration.ts#LinearScrollAccel.tick [status=implemented hash=f6d3b7afe1a3]
    public func tick(now: Double = 0) -> Double {
        1.0
    }

    // parity: core/src/lib/scroll-acceleration.ts#LinearScrollAccel.reset [status=implemented hash=970cb8d0b1d5]
    public func reset() {}
}

public struct MacOSScrollAccelOptions: Equatable, Hashable, Sendable, Codable {
    public var A: Double
    public var tau: Double
    public var maxMultiplier: Double

    public init(A: Double = 0.8, tau: Double = 3.0, maxMultiplier: Double = 6.0) {
        self.A = A
        self.tau = tau
        self.maxMultiplier = maxMultiplier
    }
}

/// macOS-inspired exponential scroll acceleration matching `core/src/lib/scroll-acceleration.ts`.
// parity: core/src/lib/scroll-acceleration.ts#MacOSScrollAccel [status=implemented hash=d37ab452badf]
public struct MacOSScrollAccel: ScrollAcceleration, Equatable, Sendable {
    public let options: MacOSScrollAccelOptions
    private var lastTickTime: Double = 0
    private var velocityHistory: [Double] = []
    private let historySize: Int = 3
    private let streakTimeout: Double = 150
    private let minTickInterval: Double = 6

    public init(options: MacOSScrollAccelOptions = MacOSScrollAccelOptions()) {
        self.options = options
    }

    public init(A: Double = 0.8, tau: Double = 3.0, maxMultiplier: Double = 6.0) {
        self.options = MacOSScrollAccelOptions(A: A, tau: tau, maxMultiplier: maxMultiplier)
    }

    // parity: core/src/lib/scroll-acceleration.ts#MacOSScrollAccel.tick [status=implemented hash=de481bbfa863]
    public mutating func tick(now: Double) -> Double {
        let A = options.A
        let tau = options.tau
        let maxMultiplier = options.maxMultiplier

        let dt = lastTickTime != 0 ? (now - lastTickTime) : Double.infinity

        // Reset streak if too much time has passed or first tick
        if dt.isInfinite || dt > streakTimeout {
            lastTickTime = now
            velocityHistory.removeAll()
            return 1.0
        }

        // Ignore ticks closer than minTickInterval (they're part of the same logical tick)
        if dt < minTickInterval {
            return 1.0
        }

        lastTickTime = now

        velocityHistory.append(dt)
        if velocityHistory.count > historySize {
            velocityHistory.removeFirst()
        }

        // Calculate average interval (lower = faster scrolling)
        let avgInterval = velocityHistory.reduce(0.0, +) / Double(velocityHistory.count)

        // Convert interval to velocity: faster ticks = higher velocity
        // Normalize to a reference interval (100ms = velocity of 1)
        let referenceInterval = 100.0
        let velocity = referenceInterval / avgInterval

        // Apply exponential curve based on velocity
        let x = velocity / tau
        let multiplier = 1.0 + A * (pureExp(x) - 1.0)

        if multiplier.isNaN || maxMultiplier.isNaN {
            return .nan
        }
        return min(multiplier, maxMultiplier)
    }

    // parity: core/src/lib/scroll-acceleration.ts#MacOSScrollAccel.reset [status=implemented hash=e2511e9ab6c0]
    public mutating func reset() {
        lastTickTime = 0
        velocityHistory.removeAll()
    }
}

// MARK: - Scroll Chaining

/// Direction of a mouse wheel scroll step.
public enum WheelDirection: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case up
    case down
    case left
    case right
}

/// Minimal wheel event view used by `wheelDirection`.
public struct ScrollWheelEvent: Equatable, Hashable, Sendable, Codable {
    public var direction: WheelDirection?
    public var shift: Bool

    public init(direction: WheelDirection?, shift: Bool = false) {
        self.direction = direction
        self.shift = shift
    }
}

/// Node participating in a scroll chain hierarchy.
public protocol ScrollChainNode: AnyObject {
    var scrollChainParent: (any ScrollChainNode)? { get }
}

/// Per-event scroll-claim token tracking which innermost scroller consumed a wheel event.
public final class ScrollChainToken {
    public weak var taker: (any ScrollChainNode)?

    public init(taker: (any ScrollChainNode)? = nil) {
        self.taker = taker
    }
}

/// The axis direction of a wheel step: Shift turns vertical steps sideways and sideways steps vertical.
// parity: core/src/lib/scroll-chain.ts#wheelDirection [status=implemented hash=90e4f5a1eaef]
public func wheelDirection(direction: WheelDirection?, shift: Bool = false) -> WheelDirection? {
    guard let direction else { return nil }
    guard shift else { return direction }
    switch direction {
    case .up: return .left
    case .down: return .right
    case .right: return .down
    case .left: return .up
    }
}

/// Convenience overload accepting a `ScrollWheelEvent`.
public func wheelDirection(_ event: ScrollWheelEvent) -> WheelDirection? {
    wheelDirection(direction: event.direction, shift: event.shift)
}

/// A wheel step belongs to the innermost scroller on its path that can still move that way.
/// Runs `scroll` unless a scroller inside `scroller` already took this event; `scroll` returns
/// whether `scroller` takes it. Listeners further out still see the event; only scrolling stops.
// parity: core/src/lib/scroll-chain.ts#scrollOnce [status=implemented hash=a19141f53b64]
@discardableResult
public func scrollOnce(
    event: ScrollChainToken,
    scroller: any ScrollChainNode,
    scroll: () -> Bool
) -> Bool {
    var node: (any ScrollChainNode)? = event.taker
    while let current = node {
        if current === scroller {
            return false
        }
        node = current.scrollChainParent
    }
    if scroll() {
        event.taker = scroller
        return true
    }
    return false
}

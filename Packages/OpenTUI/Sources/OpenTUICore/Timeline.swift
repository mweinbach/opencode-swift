/// Pure-Swift animation timeline, easing library, and timeline engine
/// matching `packages/core/src/animation/Timeline.ts`.
/// Uses pure Swift standard library math with zero OS/C library imports.

// MARK: - Pure-Swift Math Helpers

private func tlSinCos(_ x: Double) -> (sin: Double, cos: Double) {
    if !x.isFinite { return (.nan, .nan) }
    let twoPi = 2.0 * Double.pi
    let halfPi = 0.5 * Double.pi

    // Range-reduce x into (-2pi, 2pi), then find nearest quadrant multiple of pi/2
    // so the reduced angle r satisfies |r| <= pi/4.
    let reduced = x.truncatingRemainder(dividingBy: twoPi)
    let qDouble = (reduced / halfPi).rounded(.toNearestOrEven)
    let q = Int(qDouble)
    let r = reduced - qDouble * halfPi
    let r2 = r * r

    // Degree-15 minimax/Taylor polynomial for sin(r) on [-pi/4, pi/4] (error < 5e-17)
    let s = r * (
        1.0 + r2 * (
            -1.0 / 6.0 + r2 * (
                1.0 / 120.0 + r2 * (
                    -1.0 / 5040.0 + r2 * (
                        1.0 / 362_880.0 + r2 * (
                            -1.0 / 39_916_800.0 + r2 * (
                                1.0 / 6_227_020_800.0 + r2 * (
                                    -1.0 / 1_307_674_368_000.0
                                )
                            )
                        )
                    )
                )
            )
        )
    )

    // Degree-16 polynomial for cos(r) on [-pi/4, pi/4] (error < 2e-18)
    let c = 1.0 + r2 * (
        -0.5 + r2 * (
            1.0 / 24.0 + r2 * (
                -1.0 / 720.0 + r2 * (
                    1.0 / 40_320.0 + r2 * (
                        -1.0 / 3_628_800.0 + r2 * (
                            1.0 / 479_001_600.0 + r2 * (
                                -1.0 / 87_178_291_200.0 + r2 * (
                                    1.0 / 20_922_789_888_000.0
                                )
                            )
                        )
                    )
                )
            )
        )
    )

    switch ((q % 4) + 4) % 4 {
    case 0: return (s, c)
    case 1: return (c, -s)
    case 2: return (-s, -c)
    default: return (-c, s)
    }
}

@inline(__always)
private func tlSin(_ x: Double) -> Double {
    tlSinCos(x).sin
}

@inline(__always)
private func tlCos(_ x: Double) -> Double {
    tlSinCos(x).cos
}

/// Computes `2^x` using exact IEEE-754 exponent scaling and a degree-13 polynomial on `[-0.5, 0.5]`.
private func tlExp2(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    if x <= -1075.0 { return 0.0 }
    if x >= 1024.0 { return .infinity }

    let nDouble = x.rounded(.toNearestOrEven)
    let n = Int(nDouble)
    let f = x - nDouble
    let ln2 = 0.693147180559945309417232121458176568
    let u = f * ln2

    // Horner evaluation of exp(u) for |u| <= 0.3466 (error < 4e-18)
    let expFrac = 1.0 + u * (
        1.0 + u * (
            0.5 + u * (
                1.0 / 6.0 + u * (
                    1.0 / 24.0 + u * (
                        1.0 / 120.0 + u * (
                            1.0 / 720.0 + u * (
                                1.0 / 5040.0 + u * (
                                    1.0 / 40_320.0 + u * (
                                        1.0 / 362_880.0 + u * (
                                            1.0 / 3_628_800.0 + u * (
                                                1.0 / 39_916_800.0 + u * (
                                                    1.0 / 479_001_600.0 + u * (
                                                        1.0 / 6_227_020_800.0
                                                    )
                                                )
                                            )
                                        )
                                    )
                                )
                            )
                        )
                    )
                )
            )
        )
    )

    if n < -1022 {
        let half = n / 2
        let rem = n - half
        let s1 = Double(sign: .plus, exponent: half, significand: 1.0)
        let s2 = Double(sign: .plus, exponent: rem, significand: 1.0)
        return (expFrac * s1) * s2
    }

    let scale = Double(sign: .plus, exponent: n, significand: 1.0)
    return expFrac * scale
}

// MARK: - Easing Library

/// Custom easing function mapping normalized progress `t` in `[0, 1]` to eased progress.
public typealias EasingFunction = @Sendable (Double) -> Double

/// Complete set of standard easing curves, including all curves from `animation/Timeline.ts`.
public enum EasingName: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
    case linear
    case inQuad
    case outQuad
    case inOutQuad
    case inCubic
    case outCubic
    case inOutCubic
    case inQuart
    case outQuart
    case inOutQuart
    case inQuint
    case outQuint
    case inOutQuint
    case inSine
    case outSine
    case inOutSine
    case inExpo
    case outExpo
    case inOutExpo
    case inCirc
    case outCirc
    case inOutCirc
    case inBack
    case outBack
    case inOutBack
    case inElastic
    case outElastic
    case inOutElastic
    case inBounce
    case outBounce
    case inOutBounce

    /// Evaluates this easing curve at normalized time `t`.
    public func evaluate(_ t: Double) -> Double {
        switch self {
        case .linear:
            return t

        case .inQuad:
            return t * t
        case .outQuad:
            return t * (2.0 - t)
        case .inOutQuad:
            return t < 0.5 ? 2.0 * t * t : -1.0 + (4.0 - 2.0 * t) * t

        case .inCubic:
            return t * t * t
        case .outCubic:
            let u = t - 1.0
            return u * u * u + 1.0
        case .inOutCubic:
            if t < 0.5 { return 4.0 * t * t * t }
            let u = -2.0 * t + 2.0
            return 1.0 - (u * u * u) / 2.0

        case .inQuart:
            let t2 = t * t
            return t2 * t2
        case .outQuart:
            let u = 1.0 - t
            let u2 = u * u
            return 1.0 - u2 * u2
        case .inOutQuart:
            if t < 0.5 {
                let t2 = t * t
                return 8.0 * t2 * t2
            }
            let u = -2.0 * t + 2.0
            let u2 = u * u
            return 1.0 - (u2 * u2) / 2.0

        case .inQuint:
            let t2 = t * t
            return t2 * t2 * t
        case .outQuint:
            let u = 1.0 - t
            let u2 = u * u
            return 1.0 - u2 * u2 * u
        case .inOutQuint:
            if t < 0.5 {
                let t2 = t * t
                return 16.0 * t2 * t2 * t
            }
            let u = -2.0 * t + 2.0
            let u2 = u * u
            return 1.0 - (u2 * u2 * u) / 2.0

        case .inSine:
            return 1.0 - tlCos((t * Double.pi) / 2.0)
        case .outSine:
            return tlSin((t * Double.pi) / 2.0)
        case .inOutSine:
            return -(tlCos(Double.pi * t) - 1.0) / 2.0

        case .inExpo:
            return t == 0.0 ? 0.0 : tlExp2(10.0 * (t - 1.0))
        case .outExpo:
            return t == 1.0 ? 1.0 : 1.0 - tlExp2(-10.0 * t)
        case .inOutExpo:
            if t == 0.0 { return 0.0 }
            if t == 1.0 { return 1.0 }
            if t < 0.5 { return tlExp2(20.0 * t - 10.0) / 2.0 }
            return (2.0 - tlExp2(-20.0 * t + 10.0)) / 2.0

        case .inCirc:
            return 1.0 - max(0.0, 1.0 - t * t).squareRoot()
        case .outCirc:
            let u = t - 1.0
            return max(0.0, 1.0 - u * u).squareRoot()
        case .inOutCirc:
            let x = t * 2.0
            if x < 1.0 {
                return -0.5 * (max(0.0, 1.0 - x * x).squareRoot() - 1.0)
            }
            let y = x - 2.0
            return 0.5 * (max(0.0, 1.0 - y * y).squareRoot() + 1.0)

        case .inBack:
            let s = 1.70158
            return t * t * ((s + 1.0) * t - s)
        case .outBack:
            let s = 1.70158
            let u = t - 1.0
            return u * u * ((s + 1.0) * u + s) + 1.0
        case .inOutBack:
            let s = 1.70158 * 1.525
            let x = t * 2.0
            if x < 1.0 {
                return 0.5 * (x * x * ((s + 1.0) * x - s))
            }
            let y = x - 2.0
            return 0.5 * (y * y * ((s + 1.0) * y + s) + 2.0)

        case .inElastic:
            if t == 0.0 { return 0.0 }
            if t == 1.0 { return 1.0 }
            let c4 = (2.0 * Double.pi) / 3.0
            return -tlExp2(10.0 * t - 10.0) * tlSin((t * 10.0 - 10.75) * c4)
        case .outElastic:
            if t == 0.0 { return 0.0 }
            if t == 1.0 { return 1.0 }
            let c4 = (2.0 * Double.pi) / 3.0
            return tlExp2(-10.0 * t) * tlSin((t * 10.0 - 0.75) * c4) + 1.0
        case .inOutElastic:
            if t == 0.0 { return 0.0 }
            if t == 1.0 { return 1.0 }
            let c5 = (2.0 * Double.pi) / 4.5
            if t < 0.5 {
                return -(tlExp2(20.0 * t - 10.0) * tlSin((20.0 * t - 11.125) * c5)) / 2.0
            }
            return (tlExp2(-20.0 * t + 10.0) * tlSin((20.0 * t - 11.125) * c5)) / 2.0 + 1.0

        case .outBounce:
            let n1 = 7.5625
            let d1 = 2.75
            if t < 1.0 / d1 {
                return n1 * t * t
            } else if t < 2.0 / d1 {
                let u = t - 1.5 / d1
                return n1 * u * u + 0.75
            } else if t < 2.5 / d1 {
                let u = t - 2.25 / d1
                return n1 * u * u + 0.9375
            } else {
                let u = t - 2.625 / d1
                return n1 * u * u + 0.984375
            }
        case .inBounce:
            return 1.0 - EasingName.outBounce.evaluate(1.0 - t)
        case .inOutBounce:
            if t < 0.5 {
                return (1.0 - EasingName.outBounce.evaluate(1.0 - 2.0 * t)) / 2.0
            }
            return (1.0 + EasingName.outBounce.evaluate(2.0 * t - 1.0)) / 2.0
        }
    }

    /// Returns this easing curve as a closure.
    public var function: EasingFunction {
        let curve = self
        return { t in curve.evaluate(t) }
    }
}

// parity: core/src/animation/Timeline.ts#EasingFunctions [status=implemented hash=121554d6ae52]
public typealias EasingFunctions = EasingName

// MARK: - Timeline Errors & Targets

public enum TimelineError: Error, Equatable, Hashable, Sendable {
    case invalidFrameRate(Double)
    case alreadySynced
    case belongsToAnotherEngine
    case engineAlreadyAttached
    case rendererAlreadyHasEngine
    case rendererDestroyed
}

/// Loop mode for an individual timeline animation item (`false` / `true` / `N` loops).
public enum AnimationLoop: Equatable, Hashable, Sendable, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral {
    case none
    case count(Int)
    case infinite

    public init(booleanLiteral value: Bool) {
        self = value ? .infinite : .none
    }

    public init(integerLiteral value: Int) {
        self = value <= 1 ? .none : .count(value)
    }

    internal var maxLoops: Int? {
        switch self {
        case .none:
            return 1
        case .count(let n):
            return n <= 1 ? 1 : n
        case .infinite:
            return nil
        }
    }
}

/// Object whose numeric and/or `RGBA` properties can be animated by a `Timeline`.
public protocol AnimationTarget: AnyObject {
    func animationValue(for key: String) -> Double?
    func setAnimationValue(_ value: Double, for key: String)
    func animationColor(for key: String) -> RGBA?
    func setAnimationColor(_ color: RGBA, for key: String)
}

public extension AnimationTarget {
    func animationColor(for key: String) -> RGBA? { nil }
    func setAnimationColor(_ color: RGBA, for key: String) {}
}

/// Default dictionary-backed mutable `AnimationTarget` supporting both numeric and `RGBA` channels.
public final class AnimationState: AnimationTarget, @unchecked Sendable {
    public var values: [String: Double]
    public var colors: [String: RGBA]

    public init(_ values: [String: Double] = [:], colors: [String: RGBA] = [:]) {
        self.values = values
        self.colors = colors
    }

    public subscript(_ key: String) -> Double? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public subscript(color key: String) -> RGBA? {
        get { colors[key] }
        set { colors[key] = newValue }
    }

    public func animationValue(for key: String) -> Double? {
        values[key]
    }

    public func setAnimationValue(_ value: Double, for key: String) {
        values[key] = value
    }

    public func animationColor(for key: String) -> RGBA? {
        colors[key]
    }

    public func setAnimationColor(_ color: RGBA, for key: String) {
        colors[key] = color
    }
}

// MARK: - Options & Animation Snapshot

// parity: core/src/animation/Timeline.ts#TimelineOptions [status=implemented hash=18dc950768e1]
public struct TimelineOptions {
    public var duration: Double
    public var frameRate: Double?
    public var loop: Bool
    public var autoplay: Bool
    public var onComplete: (() -> Void)?
    public var onPause: (() -> Void)?

    public init(
        duration: Double = 1000.0,
        frameRate: Double? = nil,
        loop: Bool = false,
        autoplay: Bool = true,
        onComplete: (() -> Void)? = nil,
        onPause: (() -> Void)? = nil
    ) {
        self.duration = duration
        self.frameRate = frameRate
        self.loop = loop
        self.autoplay = autoplay
        self.onComplete = onComplete
        self.onPause = onPause
    }
}

// parity: core/src/animation/Timeline.ts#JSAnimation [status=implemented hash=86b03fae93d0]
public struct JSAnimation {
    public let targets: [any AnimationTarget]
    public let deltaTime: Double
    public let progress: Double
    public let currentTime: Double

    public init(
        targets: [any AnimationTarget],
        deltaTime: Double,
        progress: Double,
        currentTime: Double
    ) {
        self.targets = targets
        self.deltaTime = deltaTime
        self.progress = progress
        self.currentTime = currentTime
    }
}

// parity: core/src/animation/Timeline.ts#AnimationOptions [status=implemented hash=08401d9bf6ac]
public struct AnimationOptions {
    public var duration: Double
    public var delay: Double
    public var ease: EasingName
    public var customEase: EasingFunction?
    public var properties: [String: Double]
    public var colorProperties: [String: RGBA]
    public var onUpdate: ((JSAnimation) -> Void)?
    public var onComplete: (() -> Void)?
    public var onStart: (() -> Void)?
    public var onLoop: (() -> Void)?
    public var onPause: (() -> Void)?
    public var loop: AnimationLoop
    public var loopDelay: Double
    public var alternate: Bool
    public var once: Bool

    public init(
        duration: Double = 1000.0,
        delay: Double = 0.0,
        ease: EasingName = .linear,
        customEase: EasingFunction? = nil,
        properties: [String: Double] = [:],
        colorProperties: [String: RGBA] = [:],
        onUpdate: ((JSAnimation) -> Void)? = nil,
        onComplete: (() -> Void)? = nil,
        onStart: (() -> Void)? = nil,
        onLoop: (() -> Void)? = nil,
        onPause: (() -> Void)? = nil,
        loop: AnimationLoop = .none,
        loopDelay: Double = 0.0,
        alternate: Bool = false,
        once: Bool = false
    ) {
        self.duration = duration
        self.delay = delay
        self.ease = ease
        self.customEase = customEase
        self.properties = properties
        self.colorProperties = colorProperties
        self.onUpdate = onUpdate
        self.onComplete = onComplete
        self.onStart = onStart
        self.onLoop = onLoop
        self.onPause = onPause
        self.loop = loop
        self.loopDelay = loopDelay
        self.alternate = alternate
        self.once = once
    }
}

/// Opaque handle returned by `Timeline.addStateChangeListener(_:)`.
public struct TimelineListenerToken: Equatable, Hashable, Sendable {
    fileprivate let id: UInt64
}

// MARK: - Internal Timeline Items

private final class TimelineAnimationItem {
    let startTime: Double
    let targets: [any AnimationTarget]
    let properties: [String: Double]
    let colorProperties: [String: RGBA]
    var initialValues: [[String: Double]] = []
    var initialColors: [[String: RGBA]] = []
    let duration: Double
    let ease: EasingName
    let customEase: EasingFunction?
    let loop: AnimationLoop
    let loopDelay: Double
    let alternate: Bool
    let onUpdate: ((JSAnimation) -> Void)?
    let onComplete: (() -> Void)?
    let onStart: (() -> Void)?
    let onLoop: (() -> Void)?
    let onPause: (() -> Void)?
    let once: Bool
    var completed: Bool = false
    var started: Bool = false
    var currentLoop: Int? = 0

    init(startTime: Double, targets: [any AnimationTarget], options: AnimationOptions) {
        self.startTime = startTime + max(0.0, options.delay)
        self.targets = targets
        self.properties = options.properties
        self.colorProperties = options.colorProperties
        self.duration = options.duration
        self.ease = options.ease
        self.customEase = options.customEase
        self.loop = options.loop
        self.loopDelay = max(0.0, options.loopDelay)
        self.alternate = options.alternate
        self.onUpdate = options.onUpdate
        self.onComplete = options.onComplete
        self.onStart = options.onStart
        self.onLoop = options.onLoop
        self.onPause = options.onPause
        self.once = options.once
    }
}

private final class TimelineCallbackItem {
    let startTime: Double
    let callback: () -> Void
    var executed: Bool = false

    init(startTime: Double, callback: @escaping () -> Void) {
        self.startTime = startTime
        self.callback = callback
    }
}

private final class TimelineSubTimelineItem {
    let startTime: Double
    let timeline: Timeline
    var timelineStarted: Bool = false

    init(startTime: Double, timeline: Timeline) {
        self.startTime = startTime
        self.timeline = timeline
    }
}

private enum TimelineEntry {
    case animation(TimelineAnimationItem)
    case callback(TimelineCallbackItem)
}

// MARK: - Animation Evaluation

private func captureInitialValues(_ item: TimelineAnimationItem) {
    if !item.properties.isEmpty && item.initialValues.isEmpty {
        var captured: [[String: Double]] = []
        captured.reserveCapacity(item.targets.count)
        for target in item.targets {
            var targetValues: [String: Double] = [:]
            for key in item.properties.keys {
                if let value = target.animationValue(for: key) {
                    targetValues[key] = value
                }
            }
            captured.append(targetValues)
        }
        item.initialValues = captured
    }

    if !item.colorProperties.isEmpty && item.initialColors.isEmpty {
        var capturedColors: [[String: RGBA]] = []
        capturedColors.reserveCapacity(item.targets.count)
        for target in item.targets {
            var targetColors: [String: RGBA] = [:]
            for key in item.colorProperties.keys {
                if let color = target.animationColor(for: key) {
                    targetColors[key] = color
                }
            }
            capturedColors.append(targetColors)
        }
        item.initialColors = capturedColors
    }
}

private func interpolateRGBA(from start: RGBA, to end: RGBA, progress: Double) -> RGBA {
    let r = start.r + (end.r - start.r) * progress
    let g = start.g + (end.g - start.g) * progress
    let b = start.b + (end.b - start.b) * progress
    let a = start.a + (end.a - start.a) * progress
    return RGBA.fromValues(r, g, b, a)
}

private func applyAnimationAtProgress(
    _ item: TimelineAnimationItem,
    progress: Double,
    reversed: Bool,
    timelineTime: Double,
    deltaTime: Double
) {
    let clamped = max(0.0, min(1.0, progress))
    let easedProgress = item.customEase?(clamped) ?? item.ease.evaluate(clamped)
    let finalProgress = reversed ? 1.0 - easedProgress : easedProgress

    if !item.properties.isEmpty && !item.initialValues.isEmpty {
        for i in 0..<item.targets.count {
            guard i < item.initialValues.count else { continue }
            let target = item.targets[i]
            let startMap = item.initialValues[i]
            for (key, endValue) in item.properties {
                guard let startValue = startMap[key] else { continue }
                let newValue = startValue + (endValue - startValue) * finalProgress
                target.setAnimationValue(newValue, for: key)
            }
        }
    }

    if !item.colorProperties.isEmpty && !item.initialColors.isEmpty {
        for i in 0..<item.targets.count {
            guard i < item.initialColors.count else { continue }
            let target = item.targets[i]
            let startMap = item.initialColors[i]
            for (key, endColor) in item.colorProperties {
                guard let startColor = startMap[key] else { continue }
                let newColor = interpolateRGBA(from: startColor, to: endColor, progress: finalProgress)
                target.setAnimationColor(newColor, for: key)
            }
        }
    }

    if let onUpdate = item.onUpdate {
        let animation = JSAnimation(
            targets: item.targets,
            deltaTime: deltaTime,
            progress: easedProgress,
            currentTime: timelineTime
        )
        onUpdate(animation)
    }
}

private func evaluateAnimation(_ item: TimelineAnimationItem, timelineTime: Double, deltaTime: Double) {
    if timelineTime < item.startTime {
        return
    }

    let animationTime = timelineTime - item.startTime
    let duration = item.duration

    if !item.started {
        captureInitialValues(item)
        item.onStart?()
        item.started = true
    }

    if duration <= 0.0 {
        if !item.completed {
            applyAnimationAtProgress(item, progress: 1.0, reversed: false, timelineTime: timelineTime, deltaTime: deltaTime)
            item.onComplete?()
            item.completed = true
        }
        return
    }

    let maxLoops = item.loop.maxLoops // nil means infinite
    let cycleTime = duration + item.loopDelay
    var currentCycle = Int((animationTime / cycleTime).rounded(.down))
    var timeInCycle = animationTime.truncatingRemainder(dividingBy: cycleTime)

    // Trigger onLoop if a non-final loop cycle completes
    if let prevLoop = item.currentLoop, currentCycle > prevLoop {
        if maxLoops == nil || currentCycle < maxLoops! {
            item.onLoop?()
        }
    }
    item.currentLoop = currentCycle

    // Check if the animation part of the final loop has just completed
    if let limit = maxLoops, !item.completed, currentCycle == limit - 1, timeInCycle >= duration {
        let finalLoopReversed = item.alternate && (currentCycle % 2 == 1)
        applyAnimationAtProgress(
            item,
            progress: 1.0,
            reversed: finalLoopReversed,
            timelineTime: timelineTime,
            deltaTime: deltaTime
        )
        item.onComplete?()
        item.completed = true
        return
    }

    if let limit = maxLoops, currentCycle >= limit {
        if !item.completed {
            let finalReversed = item.alternate && ((limit - 1) % 2 == 1)
            applyAnimationAtProgress(
                item,
                progress: 1.0,
                reversed: finalReversed,
                timelineTime: timelineTime,
                deltaTime: deltaTime
            )
            item.onComplete?()
            item.completed = true
        }
        return
    }

    if timeInCycle == 0.0 && animationTime > 0.0 && (maxLoops == nil || currentCycle < maxLoops!) {
        currentCycle -= 1
        timeInCycle = cycleTime
    }

    if timeInCycle >= duration {
        let isReversed = item.alternate && (currentCycle % 2 == 1)
        applyAnimationAtProgress(item, progress: 1.0, reversed: isReversed, timelineTime: timelineTime, deltaTime: deltaTime)
        return
    }

    let progress = timeInCycle / duration
    let isReversed = item.alternate && (currentCycle % 2 == 1)
    applyAnimationAtProgress(item, progress: progress, reversed: isReversed, timelineTime: timelineTime, deltaTime: deltaTime)
}

private func evaluateCallback(_ item: TimelineCallbackItem, timelineTime: Double) {
    if !item.executed && timelineTime >= item.startTime {
        item.callback()
        item.executed = true
    }
}

private func evaluateTimelineSync(_ item: TimelineSubTimelineItem, timelineTime: Double, deltaTime: Double) {
    if timelineTime < item.startTime {
        return
    }

    if !item.timelineStarted {
        item.timelineStarted = true
        item.timeline.play()
        let overshoot = timelineTime - item.startTime
        item.timeline.update(deltaTime: overshoot)
        return
    }

    item.timeline.update(deltaTime: deltaTime)
}

// MARK: - Timeline

// parity: core/src/animation/Timeline.ts#Timeline [status=implemented hash=9f9ce7d81911]
public final class Timeline: @unchecked Sendable {
    private var entries: [TimelineEntry] = []
    private var subTimelines: [TimelineSubTimelineItem] = []

    public internal(set) var currentTime: Double = 0.0
    public internal(set) var isPlaying: Bool = false
    public internal(set) var isComplete: Bool = false
    public var duration: Double
    public var loop: Bool
    public let autoplay: Bool
    public internal(set) var synced: Bool = false

    private var _frameRate: Double?
    private let onCompleteCallback: (() -> Void)?
    private let onPauseCallback: (() -> Void)?

    private struct StateListenerEntry {
        let id: UInt64
        let listener: (Timeline) -> Void
    }

    private var nextListenerId: UInt64 = 1
    private var stateChangeListeners: [StateListenerEntry] = []

    public init(options: TimelineOptions = TimelineOptions()) {
        self.duration = options.duration > 0.0 ? options.duration : 1000.0
        if let fr = options.frameRate, fr > 0.0 {
            self._frameRate = fr
        } else {
            self._frameRate = nil
        }
        self.loop = options.loop
        self.autoplay = options.autoplay
        self.onCompleteCallback = options.onComplete
        self.onPauseCallback = options.onPause
    }

    /// Number of scheduled animation/callback items currently in the timeline.
    public var itemCount: Int {
        entries.count
    }

    /// Number of synced child sub-timelines.
    public var subTimelineCount: Int {
        subTimelines.count
    }

    // parity: core/src/animation/Timeline.ts#Timeline.frameRate [status=implemented hash=7e27e4a8d307]
    public var frameRate: Double? {
        get { _frameRate }
        set {
            if let value = newValue {
                precondition(value > 0.0, "frameRate must be above 0, got \(value)")
            }
            _frameRate = newValue
            notifyStateChange()
        }
    }

    /// Validates and sets `frameRate`, throwing `TimelineError.invalidFrameRate` when non-positive or NaN.
    public func setFrameRate(_ value: Double?) throws(TimelineError) {
        if let value, !(value > 0.0) {
            throw .invalidFrameRate(value)
        }
        _frameRate = value
        notifyStateChange()
    }

    // parity: core/src/animation/Timeline.ts#Timeline.addStateChangeListener [status=implemented hash=9a2573276168]
    @discardableResult
    public func addStateChangeListener(_ listener: @escaping (Timeline) -> Void) -> TimelineListenerToken {
        let id = nextListenerId
        nextListenerId &+= 1
        stateChangeListeners.append(StateListenerEntry(id: id, listener: listener))
        return TimelineListenerToken(id: id)
    }

    // parity: core/src/animation/Timeline.ts#Timeline.removeStateChangeListener [status=implemented hash=17cb045dfd9c]
    public func removeStateChangeListener(_ token: TimelineListenerToken) {
        stateChangeListeners.removeAll { $0.id == token.id }
    }

    private func notifyStateChange() {
        let snapshot = stateChangeListeners
        for entry in snapshot {
            entry.listener(self)
        }
    }

    // parity: core/src/animation/Timeline.ts#Timeline.add [status=implemented hash=c854a01611b7]
    @discardableResult
    public func add(
        _ targets: [any AnimationTarget],
        options: AnimationOptions,
        startTime: Double = 0.0
    ) -> Timeline {
        entries.append(.animation(TimelineAnimationItem(startTime: startTime, targets: targets, options: options)))
        return self
    }

    @discardableResult
    public func add(
        _ target: any AnimationTarget,
        options: AnimationOptions,
        startTime: Double = 0.0
    ) -> Timeline {
        add([target], options: options, startTime: startTime)
    }

    // parity: core/src/animation/Timeline.ts#Timeline.once [status=implemented hash=fe5fabb43cc6]
    @discardableResult
    public func once(_ targets: [any AnimationTarget], options: AnimationOptions) -> Timeline {
        var onceOptions = options
        onceOptions.once = true
        return add(targets, options: onceOptions, startTime: currentTime)
    }

    @discardableResult
    public func once(_ target: any AnimationTarget, options: AnimationOptions) -> Timeline {
        once([target], options: options)
    }

    // parity: core/src/animation/Timeline.ts#Timeline.call [status=implemented hash=2b64f5f0a528]
    @discardableResult
    public func call(_ callback: @escaping () -> Void, startTime: Double = 0.0) -> Timeline {
        entries.append(.callback(TimelineCallbackItem(startTime: startTime, callback: callback)))
        return self
    }

    // parity: core/src/animation/Timeline.ts#Timeline.sync [status=implemented hash=bcd3e51940a6]
    @discardableResult
    public func sync(_ timeline: Timeline, startTime: Double = 0.0) throws(TimelineError) -> Timeline {
        guard !timeline.synced else {
            throw .alreadySynced
        }
        subTimelines.append(TimelineSubTimelineItem(startTime: startTime, timeline: timeline))
        timeline.synced = true
        return self
    }

    // parity: core/src/animation/Timeline.ts#Timeline.play [status=implemented hash=e7c3d83dcb64]
    @discardableResult
    public func play() -> Timeline {
        if isComplete {
            return restart()
        }
        for subTimeline in subTimelines where subTimeline.timelineStarted {
            subTimeline.timeline.play()
        }
        isPlaying = true
        notifyStateChange()
        return self
    }

    // parity: core/src/animation/Timeline.ts#Timeline.pause [status=implemented hash=8f1c4b67f76d]
    @discardableResult
    public func pause() -> Timeline {
        for subTimeline in subTimelines {
            subTimeline.timeline.pause()
        }
        isPlaying = false
        for entry in entries {
            if case .animation(let item) = entry, item.started && !item.completed {
                item.onPause?()
            }
        }
        onPauseCallback?()
        notifyStateChange()
        return self
    }

    // parity: core/src/animation/Timeline.ts#Timeline.resetItems [status=implemented hash=742b23b2d2ac]
    public func resetItems() {
        for entry in entries {
            switch entry {
            case .callback(let cb):
                cb.executed = false
            case .animation(let anim):
                anim.completed = false
                anim.started = false
                anim.currentLoop = 0
            }
        }
        for subTimeline in subTimelines {
            subTimeline.timelineStarted = false
            subTimeline.timeline.restart()
            subTimeline.timeline.pause()
        }
    }

    // parity: core/src/animation/Timeline.ts#Timeline.restart [status=implemented hash=1b50a492788c]
    @discardableResult
    public func restart() -> Timeline {
        isComplete = false
        currentTime = 0.0
        isPlaying = true
        resetItems()
        notifyStateChange()
        return self
    }

    // parity: core/src/animation/Timeline.ts#Timeline.update [status=implemented hash=c9b0c1082ccb]
    public func update(deltaTime: Double) {
        for subTimeline in subTimelines {
            evaluateTimelineSync(subTimeline, timelineTime: currentTime + deltaTime, deltaTime: deltaTime)
        }

        if !isPlaying { return }

        currentTime += deltaTime

        for entry in entries {
            switch entry {
            case .animation(let anim):
                evaluateAnimation(anim, timelineTime: currentTime, deltaTime: deltaTime)
            case .callback(let cb):
                evaluateCallback(cb, timelineTime: currentTime)
            }
        }

        // Remove completed "once" items backwards to avoid index shifting
        var idx = entries.count - 1
        while idx >= 0 {
            if case .animation(let anim) = entries[idx], anim.once && anim.completed {
                entries.remove(at: idx)
            }
            idx -= 1
        }

        if loop && currentTime >= duration && duration > 0.0 {
            let overshoot = currentTime.truncatingRemainder(dividingBy: duration)
            resetItems()
            currentTime = 0.0
            if overshoot > 0.0 {
                update(deltaTime: overshoot)
            }
        } else if !loop && currentTime >= duration {
            currentTime = duration
            isPlaying = false
            isComplete = true
            onCompleteCallback?()
            notifyStateChange()
        }
    }
}

// MARK: - TimelineRendererHost & TimelineEngine

/// Renderer host surface that a `TimelineEngine` can attach to for frame/tick scheduling.
public protocol TimelineRendererHost: AnyObject {
    var isDestroyed: Bool { get }
    var targetFps: Double { get }
    func requestLive()
    func dropLive()
    func setFrameCallback(_ id: ObjectIdentifier, callback: @escaping (Double) -> Void)
    func removeFrameCallback(_ id: ObjectIdentifier)
    func hasFrameCallback(_ id: ObjectIdentifier) -> Bool
    func onAnimationTick(fps: Double, callback: @escaping (Double) -> Void) -> () -> Void
}

private final class EngineRegistry: @unchecked Sendable {
    var rendererEngines: [ObjectIdentifier: TimelineEngine] = [:]
    var timelineOwners: [ObjectIdentifier: TimelineEngine] = [:]
}

private let timelineRegistry = EngineRegistry()

/// Manages registration, live-loop coordination, pausing, and stepping of `Timeline` instances.
public final class TimelineEngine: @unchecked Sendable {
    public struct Defaults: Equatable, Sendable {
        public var frameRate: Double

        public init(frameRate: Double = 60.0) {
            self.frameRate = frameRate
        }
    }

    private var timelines: [ObjectIdentifier: Timeline] = [:]
    private var listenerTokens: [ObjectIdentifier: TimelineListenerToken] = [:]
    private var pausedByEngine: Set<ObjectIdentifier> = []
    private weak var renderer: (any TimelineRendererHost)?
    private var isLive: Bool = false
    private var tickFps: Double = 0.0
    private var stopTicks: (() -> Void)?

    public private(set) var isPaused: Bool = false
    public var defaults: Defaults = Defaults()

    public init() {}

    /// Number of currently registered timelines.
    public var count: Int {
        timelines.count
    }

    internal var attachedRendererId: ObjectIdentifier? {
        renderer.map(ObjectIdentifier.init)
    }

    public func attach(_ renderer: any TimelineRendererHost) throws(TimelineError) {
        if renderer.isDestroyed {
            throw .rendererDestroyed
        }
        let rendererId = ObjectIdentifier(renderer)
        let engineId = ObjectIdentifier(self)

        if let current = self.renderer, ObjectIdentifier(current) == rendererId {
            if !renderer.hasFrameCallback(engineId) {
                renderer.setFrameCallback(engineId) { [weak self] dt in
                    guard let self else { return }
                    if self.tickFps == 0.0 {
                        self.update(deltaTime: dt)
                    }
                }
            }
            return
        }

        if self === engine {
            detach()
        } else if self.renderer != nil {
            throw .engineAlreadyAttached
        } else if timelineRegistry.rendererEngines[rendererId] != nil {
            throw .rendererAlreadyHasEngine
        } else {
            timelineRegistry.rendererEngines[rendererId] = self
        }

        self.renderer = renderer
        renderer.setFrameCallback(engineId) { [weak self] dt in
            guard let self else { return }
            if self.tickFps == 0.0 {
                self.update(deltaTime: dt)
            }
        }
        updateLiveState()
    }

    public func detach() {
        if let renderer {
            let rendererId = ObjectIdentifier(renderer)
            if self !== engine {
                timelineRegistry.rendererEngines.removeValue(forKey: rendererId)
            }
            renderer.removeFrameCallback(ObjectIdentifier(self))
            if isLive {
                renderer.dropLive()
                isLive = false
            }
            setTickFps(0.0)
        }
        renderer = nil
    }

    private func updateLiveState() {
        guard let renderer else { return }
        if isPaused {
            if isLive {
                renderer.dropLive()
                isLive = false
            }
            setTickFps(0.0)
            return
        }

        var fps = 0.0
        for timeline in timelines.values {
            if timeline.synced || !timeline.isPlaying || timeline.isComplete { continue }
            fps = max(fps, timeline.frameRate ?? defaults.frameRate)
        }

        let live = fps > 0.0 && fps >= renderer.targetFps
        if live && !isLive {
            renderer.requestLive()
            isLive = true
        } else if !live && isLive {
            renderer.dropLive()
            isLive = false
        }
        setTickFps(live ? 0.0 : fps)
    }

    private func setTickFps(_ fps: Double) {
        if fps == tickFps { return }
        stopTicks?()
        if fps > 0.0, let renderer {
            stopTicks = renderer.onAnimationTick(fps: fps) { [weak self] dt in
                self?.update(deltaTime: dt)
            }
        } else {
            stopTicks = nil
        }
        tickFps = fps
    }

    public func register(_ timeline: Timeline) throws(TimelineError) {
        let tid = ObjectIdentifier(timeline)
        if let owner = timelineRegistry.timelineOwners[tid], owner !== self {
            throw .belongsToAnotherEngine
        }
        if timelines[tid] == nil {
            timelineRegistry.timelineOwners[tid] = self
            timelines[tid] = timeline
            let token = timeline.addStateChangeListener { [weak self] _ in
                self?.updateLiveState()
            }
            listenerTokens[tid] = token
            updateLiveState()
        }
    }

    public func unregister(_ timeline: Timeline) {
        let tid = ObjectIdentifier(timeline)
        guard timelines.removeValue(forKey: tid) != nil else { return }
        timelineRegistry.timelineOwners.removeValue(forKey: tid)
        pausedByEngine.remove(tid)
        if let token = listenerTokens.removeValue(forKey: tid) {
            timeline.removeStateChangeListener(token)
        }
        updateLiveState()
    }

    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        pausedByEngine.removeAll(keepingCapacity: true)
        for (tid, timeline) in timelines {
            if !timeline.synced && timeline.isPlaying {
                pausedByEngine.insert(tid)
                timeline.pause()
            }
        }
        updateLiveState()
    }

    public func resume() {
        guard isPaused else { return }
        isPaused = false
        let toResume = pausedByEngine
        pausedByEngine.removeAll(keepingCapacity: true)
        for tid in toResume {
            if let timeline = timelines[tid], !timeline.isComplete {
                timeline.play()
            }
        }
        updateLiveState()
    }

    public func clear() {
        for (tid, timeline) in timelines {
            timelineRegistry.timelineOwners.removeValue(forKey: tid)
            if let token = listenerTokens[tid] {
                timeline.removeStateChangeListener(token)
            }
        }
        timelines.removeAll()
        listenerTokens.removeAll()
        pausedByEngine.removeAll()
        isPaused = false
        updateLiveState()
    }

    public func update(deltaTime: Double) {
        guard !isPaused else { return }
        let snapshot = Array(timelines.values)
        for timeline in snapshot {
            if renderer?.isDestroyed == true { break }
            if !timeline.synced {
                timeline.update(deltaTime: deltaTime)
            }
        }
    }
}

// MARK: - Global Engine & Factory Helpers

// parity: core/src/animation/Timeline.ts#engine [status=implemented hash=7835b4406491]
public let engine = TimelineEngine()

// parity: core/src/animation/Timeline.ts#getTimelineEngine [status=implemented hash=89c00c75ffab]
public func getTimelineEngine(_ renderer: any TimelineRendererHost) throws(TimelineError) -> TimelineEngine {
    let rid = ObjectIdentifier(renderer)
    let owner = timelineRegistry.rendererEngines[rid] ?? TimelineEngine()
    try owner.attach(renderer)
    return owner
}

// parity: core/src/animation/Timeline.ts#destroyTimelineEngine [status=implemented hash=744b5354ba7a]
public func destroyTimelineEngine(_ renderer: any TimelineRendererHost) {
    let rid = ObjectIdentifier(renderer)
    if let owner = timelineRegistry.rendererEngines[rid] {
        owner.clear()
        owner.detach()
    }
    if engine.attachedRendererId == rid {
        engine.detach()
    }
}

// parity: core/src/animation/Timeline.ts#createTimeline [status=implemented hash=b888a2912eec]
public func createTimeline(
    options: TimelineOptions = TimelineOptions(),
    renderer: (any TimelineRendererHost)? = nil
) -> Timeline {
    let owner: TimelineEngine
    if let renderer, let attached = try? getTimelineEngine(renderer) {
        owner = attached
    } else {
        owner = engine
    }
    let timeline = Timeline(options: options)
    if options.autoplay {
        timeline.play()
    }
    try? owner.register(timeline)
    return timeline
}

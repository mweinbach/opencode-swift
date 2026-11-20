#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(CRT)
import CRT
#elseif canImport(WASILibc)
import WASILibc
#endif
import Foundation
import OpenCodeUtil
import OpenTUICore
import OpenTUIKeymap
import OpenTUILayout
import OpenTUIRenderables
import OpenTUIView
import Synchronization

/// Cross-platform UI primitives (`packages/tui/src/ui/*`) built on `OpenTUIRenderables`, `OpenTUIView`,
/// and resolved `OpenCodeTUI` semantic themes.
public enum TUIPrimitive {

    // MARK: - Animation (`src/ui/animation.ts`)

    public enum AnimatableValue: Equatable, Sendable {
        case scalar(Double)
        case vector([Double])

        public var elements: [Double] {
            switch self {
            case .scalar(let v): return [v]
            case .vector(let vs): return vs
            }
        }

        public var isScalar: Bool {
            if case .scalar = self { return true }
            return false
        }

        public var scalarValue: Double {
            switch self {
            case .scalar(let v): return v
            case .vector(let vs): return vs.first ?? 0
            }
        }
    }

    public typealias AnimatableTarget = [String: AnimatableValue]
    public typealias EaseFunction = @Sendable (Double) -> Double

    public enum Transition: Sendable {
        case spring(visualDuration: Double, restDelta: Double, restSpeed: Double)
        case tween(duration: Double, ease: EaseFunction)
    }

    private static let defaultSmoothstep: EaseFunction = { progress in
        let clamped = max(0, min(1, progress))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// Creates a critically-damped spring transition matching `ui/animation.ts#spring`.
    // parity: tui/src/ui/animation.ts#spring [status=implemented hash=32a439957965]
    public static func spring(
        visualDuration: Double,
        restDelta: Double = 0.002,
        restSpeed: Double = 0.002
    ) -> Transition {
        .spring(visualDuration: visualDuration, restDelta: restDelta, restSpeed: restSpeed)
    }

    /// Creates a timed easing transition matching `ui/animation.ts#tween`.
    // parity: tui/src/ui/animation.ts#tween [status=implemented hash=5cf6a3bed3c1]
    public static func tween(
        duration: Double,
        ease: EaseFunction? = nil
    ) -> Transition {
        .tween(duration: duration, ease: ease ?? defaultSmoothstep)
    }

    /// A renderer an animatable runs on, held weakly so a handle never keeps its renderer alive.
    public final class AnimatableRenderer: @unchecked Sendable {
        public weak var ctx: (any RenderContext)?

        public init(_ ctx: any RenderContext) {
            self.ctx = ctx
        }

        public func now() -> Double { ctx?.clock.now() ?? 0 }
    }

    /// One 60 fps subscription on each renderer's shared animation clock while any of its tasks runs. Tasks belong to
    /// no node, so a hidden view's tween runs to its end; it stops early only when its handle jumps or stops.
    private final class AnimationClock: @unchecked Sendable {
        let tasks = Mutex<[ObjectIdentifier: AnimatableHandle]>([:])
        var stop: (() -> Void)?

        private static let clocks = Mutex<[ObjectIdentifier: AnimationClock]>([:])

        static func schedule(_ renderer: AnimatableRenderer, _ task: AnimatableHandle) {
            guard let ctx = renderer.ctx else { return }
            let key = ObjectIdentifier(ctx)
            let (clock, created) = clocks.withLock { clocks -> (AnimationClock, Bool) in
                if let clock = clocks[key] { return (clock, false) }
                let clock = AnimationClock()
                clocks[key] = clock
                return (clock, true)
            }
            clock.tasks.withLock { $0[ObjectIdentifier(task)] = task }
            guard created else { return }
            clock.stop = ctx.onAnimationTick(fps: 60) { [weak renderer] _, _, now in
                guard let renderer else { return }
                for task in clock.tasks.withLock({ Array($0.values) }) where !task.step(at: now) {
                    unschedule(renderer, task)
                }
                renderer.ctx?.requestRender()
            }
        }

        static func unschedule(_ renderer: AnimatableRenderer, _ task: AnimatableHandle) {
            guard let ctx = renderer.ctx else { return }
            let key = ObjectIdentifier(ctx)
            let emptied = clocks.withLock { clocks -> AnimationClock? in
                guard let clock = clocks[key] else { return nil }
                let removed = clock.tasks.withLock { tasks -> Bool in
                    guard tasks.removeValue(forKey: ObjectIdentifier(task)) != nil else { return false }
                    return tasks.isEmpty
                }
                guard removed else { return nil }
                clocks.removeValue(forKey: key)
                return clock
            }
            emptied?.stop?()
        }
    }

    /// Deterministic frame-stepped animatable state controller supporting spring and tween transitions.
    ///
    /// Bound to a renderer, it reads time from the renderer's clock and steps itself on the renderer's shared 60 fps
    /// animation clock while it moves; without one, the caller steps it with ``step(at:)``.
    public final class AnimatableHandle: Sendable {
        private struct ChannelState: Sendable {
            var scalar: Bool
            var value: [Double]
            var target: [Double]
            var velocity: [Double]
            var from: [Double]
        }

        private struct Storage: Sendable {
            var channels: [String: ChannelState]
            var target: AnimatableTarget
            var startedMs: Double
            var previousMs: Double
            var active: Bool
        }

        private let transition: Transition
        private let enabledProvider: @Sendable () -> Bool
        private let nowProvider: @Sendable () -> Double
        private let renderer: AnimatableRenderer?
        private let storage: Mutex<Storage>

        public init(
            initial: AnimatableTarget,
            transition: Transition,
            enabled: (@Sendable () -> Bool)? = nil,
            now: (@Sendable () -> Double)? = nil,
            renderer: (any RenderContext)? = nil
        ) {
            let bound = renderer.map(AnimatableRenderer.init)
            let start = now?() ?? bound?.now() ?? 0.0
            self.transition = transition
            self.enabledProvider = enabled ?? { true }
            self.renderer = bound
            if let now {
                self.nowProvider = now
            } else if let bound {
                self.nowProvider = { bound.now() }
            } else {
                self.nowProvider = { Date().timeIntervalSinceReferenceDate * 1000.0 }
            }
            var channels: [String: ChannelState] = [:]
            for (k, v) in initial {
                let elems = v.elements
                channels[k] = ChannelState(
                    scalar: v.isScalar,
                    value: elems,
                    target: elems,
                    velocity: Array(repeating: 0, count: elems.count),
                    from: elems
                )
            }
            self.storage = Mutex(
                Storage(
                    channels: channels,
                    target: initial,
                    startedMs: start,
                    previousMs: start,
                    active: false
                )
            )
        }

        public func value() -> AnimatableTarget {
            storage.withLock { state in
                var out: AnimatableTarget = [:]
                for (key, channel) in state.channels {
                    out[key] = channel.scalar ? .scalar(channel.value.first ?? 0) : .vector(channel.value)
                }
                return out
            }
        }

        public var isAnimating: Bool {
            storage.withLock { $0.active }
        }

        public func animate(to next: AnimatableTarget, at nowMs: Double? = nil) {
            let timestamp = nowMs ?? nowProvider()
            let isEnabled = enabledProvider()
            let active = storage.withLock { state -> Bool? in
                if Self.sameTarget(next, in: state.channels) { return nil }
                state.target = next
                if !isEnabled || !Self.sameShape(next, in: state.channels) {
                    Self.rebuild(&state, with: next, at: timestamp)
                    state.active = false
                    return false
                }
                state.startedMs = timestamp
                state.previousMs = timestamp
                for (key, nextValue) in next {
                    if var ch = state.channels[key] {
                        ch.from = ch.value
                        ch.target = nextValue.elements
                        state.channels[key] = ch
                    }
                }
                if Self.isSettled(state.channels) {
                    Self.rebuild(&state, with: next, at: timestamp)
                    state.active = false
                    return false
                }
                state.active = true
                return true
            }
            guard let active, let renderer else { return }
            if active {
                AnimationClock.schedule(renderer, self)
            } else {
                AnimationClock.unschedule(renderer, self)
            }
        }

        public func jump(to next: AnimatableTarget, at nowMs: Double? = nil) {
            let timestamp = nowMs ?? nowProvider()
            storage.withLock { state in
                state.target = next
                Self.rebuild(&state, with: next, at: timestamp)
                state.active = false
            }
            if let renderer { AnimationClock.unschedule(renderer, self) }
        }

        public func stop() {
            storage.withLock { $0.active = false }
            if let renderer { AnimationClock.unschedule(renderer, self) }
        }

        /// Advances the animation to `nowMs`. Returns `true` while still moving.
        @discardableResult
        public func step(at nowMs: Double) -> Bool {
            let isEnabled = enabledProvider()
            return storage.withLock { state in
                guard state.active else { return false }
                if !isEnabled {
                    Self.rebuild(&state, with: state.target, at: nowMs)
                    state.active = false
                    return false
                }
                let delta = min(0.05, max(0.0, (nowMs - state.previousMs) / 1_000.0))
                state.previousMs = nowMs
                let moving: Bool
                switch transition {
                case .spring(let visualDuration, let restDelta, let restSpeed):
                    let frequency = (2.0 * Double.pi) / (max(0.001, visualDuration) * 1.2)
                    var anyMoving = false
                    for key in state.channels.keys {
                        guard var ch = state.channels[key] else { continue }
                        for i in 0..<ch.value.count {
                            let target = ch.target[i]
                            let velocity = ch.velocity[i]
                            let offset = ch.value[i] - target
                            let decay = exp(-frequency * delta)
                            let nextVel = velocity + frequency * offset
                            ch.value[i] = target + (offset + nextVel * delta) * decay
                            ch.velocity[i] = (velocity - frequency * nextVel * delta) * decay
                            if abs(ch.value[i] - target) > restDelta || abs(ch.velocity[i]) > restSpeed {
                                anyMoving = true
                            }
                        }
                        state.channels[key] = ch
                    }
                    moving = anyMoving
                case .tween(let duration, let ease):
                    let progress = min(1.0, max(0.0, (nowMs - state.startedMs) / 1_000.0 / max(0.001, duration)))
                    let eased = ease(progress)
                    for key in state.channels.keys {
                        guard var ch = state.channels[key] else { continue }
                        for i in 0..<ch.value.count {
                            let from = ch.from[i]
                            ch.value[i] = from + (ch.target[i] - from) * eased
                            ch.velocity[i] = 0
                        }
                        state.channels[key] = ch
                    }
                    moving = progress < 1.0
                }
                if !moving {
                    Self.rebuild(&state, with: state.target, at: nowMs)
                    state.active = false
                    return false
                }
                return true
            }
        }

        private static func rebuild(_ state: inout Storage, with next: AnimatableTarget, at nowMs: Double) {
            state.channels.removeAll(keepingCapacity: true)
            for (k, v) in next {
                let elems = v.elements
                state.channels[k] = ChannelState(
                    scalar: v.isScalar,
                    value: elems,
                    target: elems,
                    velocity: Array(repeating: 0, count: elems.count),
                    from: elems
                )
            }
            state.startedMs = nowMs
            state.previousMs = nowMs
        }

        private static func sameShape(_ next: AnimatableTarget, in channels: [String: ChannelState]) -> Bool {
            guard next.count == channels.count else { return false }
            for (k, v) in next {
                guard let ch = channels[k], ch.scalar == v.isScalar, ch.value.count == v.elements.count else {
                    return false
                }
            }
            return true
        }

        private static func sameTarget(_ next: AnimatableTarget, in channels: [String: ChannelState]) -> Bool {
            guard sameShape(next, in: channels) else { return false }
            for (k, v) in next {
                guard let ch = channels[k], ch.target == v.elements else { return false }
            }
            return true
        }

        private static func isSettled(_ channels: [String: ChannelState]) -> Bool {
            channels.values.allSatisfy { ch in
                ch.value == ch.target && ch.velocity.allSatisfy { $0 == 0 }
            }
        }
    }

    /// Creates a spring/tween `AnimatableHandle` matching `ui/animation.ts#createAnimatable`.
    ///
    /// Pass `renderer` (upstream's `useRenderer()`) to time the animation with `renderer.clock` and step it on the
    /// renderer's shared 60 fps animation clock; without it, the caller drives ``AnimatableHandle/step(at:)``.
    // parity: tui/src/ui/animation.ts#createAnimatable [status=adapted hash=263b35f5f5c9]
    public static func createAnimatable(
        _ initial: AnimatableTarget,
        transition: Transition,
        enabled: (@Sendable () -> Bool)? = nil,
        now: (@Sendable () -> Double)? = nil,
        renderer: (any RenderContext)? = nil
    ) -> AnimatableHandle {
        AnimatableHandle(initial: initial, transition: transition, enabled: enabled, now: now, renderer: renderer)
    }

    // MARK: - Borders (`src/ui/border.ts`)

    /// Empty border character table (space horizontal, empty edges) matching `ui/border.ts#EmptyBorder`.
    // parity: tui/src/ui/border.ts#EmptyBorder [status=implemented hash=94f707011e15]
    public static let EmptyBorder = BorderCharacters(
        topLeft: "",
        topRight: "",
        bottomLeft: "",
        bottomRight: "",
        horizontal: " ",
        vertical: "",
        topT: "",
        bottomT: "",
        leftT: "",
        rightT: "",
        cross: ""
    )

    public struct SplitBorderSpec: Equatable, Hashable, Sendable {
        public let border: [BorderSide]
        public let customBorderChars: BorderCharacters

        public init(border: [BorderSide], customBorderChars: BorderCharacters) {
            self.border = border
            self.customBorderChars = customBorderChars
        }
    }

    /// Split vertical bar border (`┃` on left/right) matching `ui/border.ts#SplitBorder`.
    // parity: tui/src/ui/border.ts#SplitBorder [status=implemented hash=d14c2c01b960]
    public static let SplitBorder = SplitBorderSpec(
        border: [.left, .right],
        customBorderChars: BorderCharacters(
            topLeft: "",
            topRight: "",
            bottomLeft: "",
            bottomRight: "",
            horizontal: " ",
            vertical: "┃",
            topT: "",
            bottomT: "",
            leftT: "",
            rightT: "",
            cross: ""
        )
    )

    // MARK: - Layout Constants & Clamping (`src/ui/layout.ts`)

    // parity: tui/src/ui/layout.ts#SESSION_SIDEBAR_WIDTH [status=implemented hash=d610e288c230]
    public static let SESSION_SIDEBAR_WIDTH = 42

    // parity: tui/src/ui/layout.ts#SESSION_TABS_COMPACT_WIDTH [status=implemented hash=7b8257cacae5]
    public static let SESSION_TABS_COMPACT_WIDTH = 5

    // parity: tui/src/ui/layout.ts#SESSION_TABS_COMPACT_BREAKPOINT [status=implemented hash=db2ba5f7220c]
    public static let SESSION_TABS_COMPACT_BREAKPOINT = 12

    // parity: tui/src/ui/layout.ts#SESSION_SIDEBAR_MAX_WIDTH [status=implemented hash=8e9558e389c5]
    public static let SESSION_SIDEBAR_MAX_WIDTH = 72

    private static let sessionContentMinWidth = 44
    private static let sessionContentPreferredWidth = 64

    // parity: tui/src/ui/layout.ts#SESSION_PANEL_SPLIT_MIN_WIDTH [status=implemented hash=f6af2d1d3a91]
    public static let SESSION_PANEL_SPLIT_MIN_WIDTH = sessionContentPreferredWidth + sessionContentMinWidth

    // parity: tui/src/ui/layout.ts#sessionTabsFitVertically [status=implemented hash=88cddf116c46]
    public static func sessionTabsFitVertically(total: Int, width: Int = SESSION_SIDEBAR_WIDTH) -> Bool {
        total >= width + sessionContentPreferredWidth
    }

    // parity: tui/src/ui/layout.ts#clampSessionTabsWidth [status=implemented hash=56e2fc6524eb]
    public static func clampSessionTabsWidth(width: Int, total: Int) -> Int {
        max(
            SESSION_TABS_COMPACT_WIDTH,
            min(width, SESSION_SIDEBAR_MAX_WIDTH, total - sessionContentMinWidth)
        )
    }

    // parity: tui/src/ui/layout.ts#clampSessionPaneWidth [status=implemented hash=da52f34919bd]
    public static func clampSessionPaneWidth(width: Int, total: Int) -> Int {
        let half = max(1, total / 2)
        return max(min(24, half), min(width, max(half, total - sessionContentMinWidth)))
    }

    // MARK: - Select Controller (`src/ui/select-controller.ts`)

    public enum SelectionMovePolicy: String, Equatable, Hashable, Sendable {
        case clamp
        case wrap
    }

    // parity: tui/src/ui/select-controller.ts#reconcileSelection [status=implemented hash=20d34bc71a92]
    public static func reconcileSelection(_ selected: Int, count: Int) -> Int {
        max(0, min(count - 1, selected))
    }

    // parity: tui/src/ui/select-controller.ts#moveSelection [status=implemented hash=301c8cb30caf]
    public static func moveSelection(
        _ selected: Int,
        count: Int,
        delta: Int,
        policy: SelectionMovePolicy
    ) -> Int {
        if count <= 0 { return 0 }
        let next = selected + delta
        if policy == .clamp { return reconcileSelection(next, count: count) }
        if next < 0 { return count - 1 }
        if next >= count { return 0 }
        return next
    }

    // parity: tui/src/ui/select-controller.ts#revealSelectionOffset [status=implemented hash=032a146d6d9f]
    public static func revealSelectionOffset(
        _ offset: Int,
        count: Int,
        limit: Int,
        selected: Int
    ) -> Int {
        let maxOff = max(0, count - limit)
        if selected < offset { return min(maxOff, selected) }
        if selected >= offset + limit { return min(maxOff, selected - limit + 1) }
        return max(0, min(maxOff, offset))
    }

    // parity: tui/src/ui/select-controller.ts#reconcileSelectionWindow [status=implemented hash=3ea2ae547f27]
    public static func reconcileSelectionWindow(
        _ selected: Int,
        count: Int,
        limit: Int,
        offset: Int
    ) -> Int {
        if count <= 0 { return 0 }
        let first = reconcileSelection(offset, count: count)
        let last = min(count - 1, first + max(1, limit) - 1)
        return max(first, min(last, selected))
    }

    // parity: tui/src/ui/select-controller.ts#moveSelectionOffset [status=implemented hash=94af7505a5c9]
    public static func moveSelectionOffset(
        _ offset: Int,
        count: Int,
        limit: Int,
        selected: Int,
        direction: Int
    ) -> Int {
        let maxOff = max(0, count - limit)
        let margin = max(0, min(2, (limit - 1) / 2))
        if direction < 0 && selected < offset + margin {
            return max(0, min(maxOff, selected - margin))
        }
        if direction > 0 && selected > offset + limit - margin - 1 {
            return min(maxOff, selected - limit + margin + 1)
        }
        return max(0, min(maxOff, offset))
    }

    // MARK: - Subcell Octant Glyphs (`src/ui/subcell.ts`)

    private static let octantOverrides: [Int: String] = [
        0x00: " ",
        0x01: "\u{1CEA8}",
        0x02: "\u{1CEAB}",
        0x03: "\u{1FB82}",
        0x05: "\u{2598}",
        0x0A: "\u{259D}",
        0x0F: "\u{2580}",
        0x14: "\u{1FBE6}",
        0x28: "\u{1FBE7}",
        0x3F: "\u{1FB85}",
        0x40: "\u{1CEA3}",
        0x50: "\u{2596}",
        0x55: "\u{258C}",
        0x5A: "\u{259E}",
        0x5F: "\u{259B}",
        0x80: "\u{1CEA0}",
        0xA0: "\u{2597}",
        0xA5: "\u{259A}",
        0xAA: "\u{2590}",
        0xAF: "\u{259C}",
        0xC0: "\u{2582}",
        0xF0: "\u{2584}",
        0xF5: "\u{2599}",
        0xFA: "\u{259F}",
        0xFC: "\u{2586}",
        0xFF: "\u{2588}",
    ]

    private static let sortedOctantOverrideKeys: [Int] = octantOverrides.keys.sorted()

    /// Maps a 2x4 row-major octant bitmask (`0x00...0xFF`) to its Unicode octant/block glyph.
    // parity: tui/src/ui/subcell.ts#octantGlyph [status=implemented hash=809f06ef445e]
    public static func octantGlyph(_ mask: Int) -> String {
        if let direct = octantOverrides[mask] {
            return direct
        }
        let priorCount = sortedOctantOverrideKeys.reduce(0) { $0 + ($1 < mask ? 1 : 0) }
        let codePoint = 0x1CD00 + mask - priorCount
        if let scalar = UnicodeScalar(codePoint) {
            return String(scalar)
        }
        return " "
    }

    // MARK: - One-Cell Motion (`src/ui/one-cell-motion.ts`)

    public struct OneCellIntro: Equatable, Hashable, Sendable {
        public let frames: [String]
        public let interval: Double
        public let levels: [Double]?

        public init(frames: [String], interval: Double, levels: [Double]? = nil) {
            self.frames = frames
            self.interval = interval
            self.levels = levels
        }
    }

    public struct OneCellPace: Equatable, Hashable, Sendable {
        public let initial: Double
        public let final: Double
        public let after: Double
        public let duration: Double

        public init(initial: Double, final: Double, after: Double, duration: Double) {
            self.initial = initial
            self.final = final
            self.after = after
            self.duration = duration
        }
    }

    /// Declarative one-cell spinner motion clip matching `ui/one-cell-motion.ts#OneCellMotion`.
    // parity: tui/src/ui/one-cell-motion.ts#OneCellMotion [status=implemented hash=0100eed631b0]
    public struct OneCellMotion: Equatable, Hashable, Sendable {
        public let frames: [String]
        public let interval: Double
        public let levels: [Double]?
        public let intro: OneCellIntro?
        public let once: Bool?
        public let pace: OneCellPace?

        public init(
            frames: [String],
            interval: Double,
            levels: [Double]? = nil,
            intro: OneCellIntro? = nil,
            once: Bool? = nil,
            pace: OneCellPace? = nil
        ) {
            self.frames = frames
            self.interval = interval
            self.levels = levels
            self.intro = intro
            self.once = once
            self.pace = pace
        }
    }

    public struct OneCellFrameResult: Equatable, Hashable, Sendable {
        public let glyph: String
        public let level: Double
        public let complete: Bool

        public init(glyph: String, level: Double, complete: Bool) {
            self.glyph = glyph
            self.level = level
            self.complete = complete
        }
    }

    /// Evaluates a one-cell motion clip at `elapsed` milliseconds, integrating pace transitions smoothly.
    // parity: tui/src/ui/one-cell-motion.ts#oneCellFrame [status=implemented hash=9b8b3b424972]
    public static func oneCellFrame(_ animation: OneCellMotion, elapsed: Double) -> OneCellFrameResult {
        let introDuration = animation.intro.map { Double($0.frames.count) * $0.interval } ?? 0
        let inIntro = elapsed < introDuration && animation.intro != nil
        let frames = inIntro ? animation.intro!.frames : animation.frames
        let interval = inIntro ? animation.intro!.interval : animation.interval
        let levels = inIntro ? animation.intro!.levels : animation.levels

        let time: Double
        if inIntro {
            time = elapsed
        } else if let pace = animation.pace {
            let progress = max(0.0, min(1.0, (elapsed - pace.after) / pace.duration))
            let p3 = progress * progress * progress
            let p4 = p3 * progress
            time = (elapsed - introDuration) * pace.initial
                + (pace.final - pace.initial)
                    * (pace.duration * (p3 - p4 / 2.0) + max(0.0, elapsed - pace.after - pace.duration))
        } else {
            time = elapsed - introDuration
        }

        let count = max(1, frames.count)
        let frame = Int(floor((time * Double(count)) / (interval * Double(count))))
        let nonNegativeFrame = max(0, frame)
        let isOnce = animation.once == true
        let index = (!inIntro && isOnce) ? min(nonNegativeFrame, count - 1) : (nonNegativeFrame % count)
        return OneCellFrameResult(
            glyph: frames[index],
            level: levels?[index] ?? 1.0,
            complete: !inIntro && isOnce && nonNegativeFrame >= count - 1
        )
    }

    // parity: tui/src/ui/one-cell-motion.ts#SEED_WORK [status=implemented hash=f59823f45970]
    public static let SEED_WORK: OneCellMotion = {
        let mainLevels = (0..<40).map { index in
            0.3 + (0.7 * (1.0 - cos((Double(index) / 40.0) * 2.0 * Double.pi))) / 2.0
        }
        let introLevels = (0..<80).map { index -> Double in
            let phase = Double(index) / 80.0
            let curve: Double
            if phase < 0.125 {
                curve = phase / 0.125
            } else if phase < 0.375 {
                curve = 1.0
            } else {
                let t = (1.0 - phase) / 0.625
                curve = t * t * t
            }
            return 0.3 + 0.7 * curve
        }
        return OneCellMotion(
            frames: Array(repeating: "\u{25AA}", count: 40),
            interval: 40,
            levels: mainLevels,
            intro: OneCellIntro(
                frames: Array(repeating: "\u{25AA}", count: 80),
                interval: 40,
                levels: introLevels
            ),
            pace: OneCellPace(initial: 1.25, final: 0.5, after: 30_000, duration: 30_000)
        )
    }()

    private static let workPace = OneCellPace(initial: 1.2, final: 0.96, after: 30_000, duration: 30_000)
    private static let lowerOctantPath = [2, 3, 5, 7, 6, 4]

    // parity: tui/src/ui/one-cell-motion.ts#BLOCK_LOW_COMET [status=implemented hash=c4d18c2776c6]
    public static let BLOCK_LOW_COMET: OneCellMotion = {
        let frames: [String] = lowerOctantPath.enumerated().flatMap { index, point in
            let leading = (1 << point) | (1 << lowerOctantPath[(index + 5) % 6])
            let full = leading | (1 << lowerOctantPath[(index + 4) % 6])
            return [full, full, full, leading, leading].map(octantGlyph)
        }
        return OneCellMotion(frames: frames, interval: 40, pace: workPace)
    }()

    // parity: tui/src/ui/one-cell-motion.ts#BLOCK_SOFT_SWEEP [status=implemented hash=2165a5a18a5b]
    public static let BLOCK_SOFT_SWEEP = OneCellMotion(
        frames: [0x14, 0x14, 0x14, 0x1C, 0x3C, 0x38, 0x28, 0x28, 0x28, 0x38, 0x3C, 0x1C].map(octantGlyph),
        interval: 100,
        pace: workPace
    )

    // parity: tui/src/ui/one-cell-motion.ts#BLOCK_SOFT_SLIDE [status=implemented hash=960ded634aa6]
    public static let BLOCK_SOFT_SLIDE = OneCellMotion(
        frames: [0x14, 0x14, 0x14, 0x14, 0x14, 0x28, 0x28, 0x28, 0x28, 0x28].map(octantGlyph),
        interval: 100,
        levels: [0.55, 0.85, 1.0, 0.85, 0.55, 0.55, 0.85, 1.0, 0.85, 0.55]
    )

    // parity: tui/src/ui/one-cell-motion.ts#WORK_SPINNERS [status=implemented hash=b26cc39c1cdb]
    public static let WORK_SPINNERS: [String: OneCellMotion] = {
        let lowDuetFrames: [String] = lowerOctantPath.prefix(3).enumerated().flatMap { index, point in
            let heads = (1 << point) | (1 << lowerOctantPath[(index + 3) % 6])
            let full = heads | (1 << lowerOctantPath[(index + 2) % 6]) | (1 << lowerOctantPath[(index + 5) % 6])
            return [full, full, full, heads].map(octantGlyph)
        }
        return [
            "block-soft-slide": BLOCK_SOFT_SLIDE,
            "block-soft-sweep": BLOCK_SOFT_SWEEP,
            "block-low-comet": BLOCK_LOW_COMET,
            "block-low-duet": OneCellMotion(frames: lowDuetFrames, interval: 60),
            "block-shuttle": OneCellMotion(frames: [0x14, 0x28].map(octantGlyph), interval: 500),
            "block-bridge": OneCellMotion(
                frames: [0x14, 0x14, 0x14, 0x3C, 0x28, 0x28, 0x28, 0x3C].map(octantGlyph),
                interval: 120
            ),
            "block-squeeze": OneCellMotion(
                frames: [0x14, 0x14, 0x14, 0x10, 0x20, 0x28, 0x28, 0x28, 0x20, 0x10].map(octantGlyph),
                interval: 100
            ),
            "small-toggle": OneCellMotion(frames: ["\u{25AB}", "\u{25AA}"], interval: 320),
            "square-toggle": OneCellMotion(frames: ["\u{25A1}", "\u{25A0}"], interval: 500),
            "grow-shrink": OneCellMotion(frames: ["\u{25AB}", "\u{25AB}", "\u{25AA}", "\u{25A0}", "\u{25AA}"], interval: 180),
            "quadrant-orbit": OneCellMotion(frames: ["\u{2598}", "\u{259D}", "\u{2597}", "\u{2596}"], interval: 160),
            "crosshatch": OneCellMotion(frames: ["\u{25A7}", "\u{25A9}", "\u{25A8}", "\u{25A9}"], interval: 240),
            "density-wave": OneCellMotion(
                frames: ["\u{2591}", "\u{2591}", "\u{2591}", "\u{2592}", "\u{2593}", "\u{2588}", "\u{2593}", "\u{2592}"],
                interval: 160
            ),
            "seed": SEED_WORK,
        ]
    }()

    // parity: tui/src/ui/one-cell-motion.ts#SEED_LAUNCH [status=implemented hash=728c2830529c]
    public static let SEED_LAUNCH = OneCellMotion(
        frames: (0..<21).map { $0 < 10 ? "\u{25AB}" : "\u{25AA}" },
        interval: 40,
        levels: Array((SEED_WORK.levels ?? []).prefix(21)),
        once: true
    )

    // parity: tui/src/ui/one-cell-motion.ts#SEED_MONO [status=implemented hash=1abfbb76efc7]
    public static let SEED_MONO = OneCellMotion(frames: ["-", "\\", "|", "/"], interval: 120)

    // MARK: - Knight Rider Spinner Generators (`src/ui/spinner.ts`)

    public typealias SpinnerColorGenerator = @Sendable (Int, Int, Int, Int) -> RGBA

    private enum ScannerDirection: Sendable {
        case forward
        case backward
        case bidirectional
    }

    private struct ScannerState: Sendable {
        let activePosition: Int
        let isHolding: Bool
        let holdProgress: Int
        let holdTotal: Int
        let movementProgress: Int
        let movementTotal: Int
        let isMovingForward: Bool
    }

    private static func scannerState(
        frameIndex: Int,
        totalChars: Int,
        direction: ScannerDirection,
        holdStart: Int,
        holdEnd: Int
    ) -> ScannerState {
        let width = max(1, totalChars)
        switch direction {
        case .bidirectional:
            let forwardFrames = width
            let backwardFrames = max(0, width - 1)
            if frameIndex < forwardFrames {
                return ScannerState(
                    activePosition: frameIndex,
                    isHolding: false,
                    holdProgress: 0,
                    holdTotal: 0,
                    movementProgress: frameIndex,
                    movementTotal: forwardFrames,
                    isMovingForward: true
                )
            } else if frameIndex < forwardFrames + holdEnd {
                return ScannerState(
                    activePosition: width - 1,
                    isHolding: true,
                    holdProgress: frameIndex - forwardFrames,
                    holdTotal: holdEnd,
                    movementProgress: 0,
                    movementTotal: 0,
                    isMovingForward: true
                )
            } else if frameIndex < forwardFrames + holdEnd + backwardFrames {
                let backwardIndex = frameIndex - forwardFrames - holdEnd
                return ScannerState(
                    activePosition: max(0, width - 2 - backwardIndex),
                    isHolding: false,
                    holdProgress: 0,
                    holdTotal: 0,
                    movementProgress: backwardIndex,
                    movementTotal: backwardFrames,
                    isMovingForward: false
                )
            } else {
                return ScannerState(
                    activePosition: 0,
                    isHolding: true,
                    holdProgress: frameIndex - forwardFrames - holdEnd - backwardFrames,
                    holdTotal: holdStart,
                    movementProgress: 0,
                    movementTotal: 0,
                    isMovingForward: false
                )
            }
        case .backward:
            return ScannerState(
                activePosition: width - 1 - (frameIndex % width),
                isHolding: false,
                holdProgress: 0,
                holdTotal: 0,
                movementProgress: frameIndex % width,
                movementTotal: width,
                isMovingForward: false
            )
        case .forward:
            return ScannerState(
                activePosition: frameIndex % width,
                isHolding: false,
                holdProgress: 0,
                holdTotal: 0,
                movementProgress: frameIndex % width,
                movementTotal: width,
                isMovingForward: true
            )
        }
    }

    private static func scannerColorIndex(
        charIndex: Int,
        trailLength: Int,
        state: ScannerState
    ) -> Int {
        let directionalDistance = state.isMovingForward
            ? state.activePosition - charIndex
            : charIndex - state.activePosition
        if state.isHolding {
            return directionalDistance + state.holdProgress
        }
        if directionalDistance > 0 && directionalDistance < trailLength {
            return directionalDistance
        }
        if directionalDistance == 0 {
            return 0
        }
        return -1
    }

    /// Derives a gradient of trail colors from a single bright color using alpha falloff.
    // parity: tui/src/ui/spinner.ts#deriveTrailColors [status=implemented hash=69b5083bc521]
    public static func deriveTrailColors(_ brightColor: Color, steps: Int = 6) -> [RGBA] {
        let base = brightColor.resolved()
        var colors: [RGBA] = []
        colors.reserveCapacity(max(0, steps))
        for i in 0..<max(0, steps) {
            let alpha: Double
            let brightnessFactor: Double
            if i == 0 {
                alpha = 1.0
                brightnessFactor = 1.0
            } else if i == 1 {
                alpha = 0.9
                brightnessFactor = 1.15
            } else {
                alpha = pow(0.65, Double(i - 1))
                brightnessFactor = 1.0
            }
            colors.append(
                RGBA.fromValues(
                    min(1.0, base.r * brightnessFactor),
                    min(1.0, base.g * brightnessFactor),
                    min(1.0, base.b * brightnessFactor),
                    alpha
                )
            )
        }
        return colors
    }

    /// Derives the inactive/default dimmed color from a bright color using alpha.
    // parity: tui/src/ui/spinner.ts#deriveInactiveColor [status=implemented hash=2e4ef24fdfa0]
    public static func deriveInactiveColor(_ brightColor: Color, factor: Double = 0.2) -> RGBA {
        let base = brightColor.resolved()
        return RGBA.fromValues(base.r, base.g, base.b, factor)
    }

    // parity: tui/src/ui/spinner.ts#KnightRiderStyle [status=implemented hash=1605ce434fcb]
    public enum KnightRiderStyle: String, Equatable, Hashable, Sendable {
        case blocks
        case diamonds
    }

    // parity: tui/src/ui/spinner.ts#KnightRiderOptions [status=implemented hash=f027d8829c5a]
    public struct KnightRiderOptions: Equatable, Hashable, Sendable {
        public var width: Int
        public var style: KnightRiderStyle
        public var holdStart: Int
        public var holdEnd: Int
        public var colors: [Color]?
        public var color: Color?
        public var trailSteps: Int
        public var defaultColor: Color?
        public var inactiveFactor: Double
        public var enableFading: Bool
        public var minAlpha: Double

        public init(
            width: Int = 8,
            style: KnightRiderStyle = .diamonds,
            holdStart: Int = 30,
            holdEnd: Int = 9,
            colors: [Color]? = nil,
            color: Color? = nil,
            trailSteps: Int = 6,
            defaultColor: Color? = nil,
            inactiveFactor: Double = 0.2,
            enableFading: Bool = true,
            minAlpha: Double = 0.0
        ) {
            self.width = width
            self.style = style
            self.holdStart = holdStart
            self.holdEnd = holdEnd
            self.colors = colors
            self.color = color
            self.trailSteps = trailSteps
            self.defaultColor = defaultColor
            self.inactiveFactor = inactiveFactor
            self.enableFading = enableFading
            self.minAlpha = minAlpha
        }
    }

    private static let defaultKnightRiderColors: [RGBA] = [
        RGBA.fromHex("#ff0000"),
        RGBA.fromHex("#ff5555"),
        RGBA.fromHex("#dd0000"),
        RGBA.fromHex("#aa0000"),
        RGBA.fromHex("#770000"),
        RGBA.fromHex("#440000"),
    ]

    /// Creates frame strings for a Knight Rider style bidirectional scanner animation.
    // parity: tui/src/ui/spinner.ts#createFrames [status=implemented hash=fea085d102d6]
    public static func createFrames(_ options: KnightRiderOptions = KnightRiderOptions()) -> [String] {
        let width = options.width
        let holdStart = options.holdStart
        let holdEnd = options.holdEnd
        let resolvedColors: [RGBA] = options.colors?.map { $0.resolved() }
            ?? options.color.map { deriveTrailColors($0, steps: options.trailSteps) }
            ?? defaultKnightRiderColors
        let totalFrames = width + holdEnd + max(0, width - 1) + holdStart
        let shapes = ["⬥", "◆", "⬩", "⬪"]

        return (0..<totalFrames).map { frameIndex in
            let state = scannerState(
                frameIndex: frameIndex,
                totalChars: width,
                direction: .bidirectional,
                holdStart: holdStart,
                holdEnd: holdEnd
            )
            return (0..<width).map { charIndex in
                let idx = scannerColorIndex(charIndex: charIndex, trailLength: resolvedColors.count, state: state)
                if options.style == .diamonds {
                    if idx >= 0 && idx < resolvedColors.count {
                        return shapes[min(idx, shapes.count - 1)]
                    }
                    return "·"
                }
                let isActive = idx >= 0 && idx < resolvedColors.count
                return isActive ? "■" : "⬝"
            }.joined()
        }
    }

    /// Creates a per-cell `ColorGenerator` closure for Knight Rider style scanner animation.
    // parity: tui/src/ui/spinner.ts#createColors [status=implemented hash=1982dd9fcf70]
    public static func createColors(_ options: KnightRiderOptions = KnightRiderOptions()) -> SpinnerColorGenerator {
        let holdStart = options.holdStart
        let holdEnd = options.holdEnd
        let resolvedColors: [RGBA] = options.colors?.map { $0.resolved() }
            ?? options.color.map { deriveTrailColors($0, steps: options.trailSteps) }
            ?? defaultKnightRiderColors
        let defaultRgba: RGBA = options.defaultColor?.resolved()
            ?? options.color.map { deriveInactiveColor($0, factor: options.inactiveFactor) }
            ?? RGBA.fromHex("#330000")
        let baseInactiveAlpha = defaultRgba.a
        let enableFading = options.enableFading
        let minAlpha = options.minAlpha

        return { frameIndex, charIndex, _, totalChars in
            let state = scannerState(
                frameIndex: frameIndex,
                totalChars: totalChars,
                direction: .bidirectional,
                holdStart: holdStart,
                holdEnd: holdEnd
            )
            let idx = scannerColorIndex(charIndex: charIndex, trailLength: resolvedColors.count, state: state)
            var fadeFactor = 1.0
            if enableFading {
                if state.isHolding && state.holdTotal > 0 {
                    let progress = min(Double(state.holdProgress) / Double(state.holdTotal), 1.0)
                    fadeFactor = max(minAlpha, 1.0 - progress * (1.0 - minAlpha))
                } else if !state.isHolding && state.movementTotal > 0 {
                    let progress = min(Double(state.movementProgress) / Double(max(1, state.movementTotal - 1)), 1.0)
                    fadeFactor = minAlpha + progress * (1.0 - minAlpha)
                }
            }
            let fadedDefault = RGBA.fromValues(defaultRgba.r, defaultRgba.g, defaultRgba.b, baseInactiveAlpha * fadeFactor)
            if idx < 0 || idx >= resolvedColors.count {
                return fadedDefault
            }
            return resolvedColors[idx]
        }
    }

    // MARK: - File Path Truncation & View (`src/ui/file-path.tsx`)

    // parity: tui/src/ui/file-path.tsx#FilePathProps [status=implemented hash=1235d57db8c8]
    public struct FilePathProps: Equatable, Hashable, Sendable {
        public let value: String
        public let maxWidth: Int
        public let fg: RGBA?
        public let basenameFg: RGBA?

        public init(value: String, maxWidth: Int, fg: RGBA? = nil, basenameFg: RGBA? = nil) {
            self.value = value
            self.maxWidth = maxWidth
            self.fg = fg
            self.basenameFg = basenameFg
        }
    }

    /// Renders a truncated file path into an OpenTUI `TextRenderable` with distinct parent and basename colors.
    // parity: tui/src/ui/file-path.tsx#FilePath [status=adapted hash=97600ecfc8d4]
    public static func FilePath(ctx: any RenderContext, props: FilePathProps) -> TextRenderable {
        let truncated = truncateFilePath(props.value, maxWidth: props.maxWidth)
        let lastSlash = truncated.lastIndex(of: "/")
        let lastBackslash = truncated.lastIndex(of: "\\")
        let splitIndex: String.Index?
        switch (lastSlash, lastBackslash) {
        case (.some(let a), .some(let b)): splitIndex = max(a, b)
        case (.some(let a), .none): splitIndex = a
        case (.none, .some(let b)): splitIndex = b
        case (.none, .none): splitIndex = nil
        }
        let parent: String
        let basename: String
        if let idx = splitIndex {
            let after = truncated.index(after: idx)
            parent = String(truncated[..<after])
            basename = String(truncated[after...])
        } else {
            parent = ""
            basename = truncated
        }
        var chunks: [TextChunk] = []
        if !parent.isEmpty {
            chunks.append(TextChunk(text: parent, fg: props.fg))
        }
        chunks.append(TextChunk(text: basename, fg: props.basenameFg ?? props.fg))
        return TextRenderable(
            ctx: ctx,
            options: TextOptions(
                content: .styled(StyledText(chunks: chunks)),
                fg: props.fg.map { .rgba($0) },
                wrapMode: TextWrapMode.none,
                truncate: true
            )
        )
    }

    /// Truncates a file path to fit `maxWidth` terminal cells, preserving root and basename/extension when possible.
    // parity: tui/src/ui/file-path.tsx#truncateFilePath [status=implemented hash=f68f5522b1c4]
    public static func truncateFilePath(_ value: String, maxWidth: Int) -> String {
        if maxWidth <= 0 { return "" }
        if TUIUtil.stringWidth(value) <= maxWidth { return value }

        let chars = Array(value)
        var driveRoot: String? = nil
        var driveLen = 0
        if chars.count >= 3,
           chars[0].isASCII && chars[0].isLetter,
           chars[1] == ":",
           (chars[2] == "\\" || chars[2] == "/")
        {
            driveRoot = String(chars[0..<3])
            driveLen = 3
        }

        var uncRoot: String? = nil
        var uncLen = 0
        var uncSlash = false
        if driveRoot == nil, (value.hasPrefix("\\\\") || value.hasPrefix("//")) {
            uncSlash = value.hasPrefix("//")
            let rest = value.dropFirst(2)
            let parts = rest.split(whereSeparator: { $0 == "\\" || $0 == "/" })
            if parts.count >= 2 {
                let sep = uncSlash ? "/" : "\\"
                let prefix2 = uncSlash ? "//" : "\\\\"
                uncRoot = "\(prefix2)\(parts[0])\(sep)\(parts[1])\(sep)"
                // Compute matched prefix length in original value
                var idx = value.index(value.startIndex, offsetBy: 2)
                var seen = 0
                while idx < value.endIndex && seen < 2 {
                    while idx < value.endIndex && value[idx] != "\\" && value[idx] != "/" {
                        idx = value.index(after: idx)
                    }
                    seen += 1
                    if idx < value.endIndex {
                        idx = value.index(after: idx)
                    }
                }
                uncLen = value.distance(from: value.startIndex, to: idx)
            }
        }

        let isWindows = driveRoot != nil || uncRoot != nil || (!value.contains("/") && value.contains("\\"))
        let separator: String
        if let d = driveRoot, let last = d.last {
            separator = String(last)
        } else if uncRoot != nil {
            separator = uncSlash ? "/" : "\\"
        } else {
            separator = isWindows ? "\\" : "/"
        }

        let root: String
        let dropCount: Int
        if let d = driveRoot {
            root = d
            dropCount = driveLen
        } else if let u = uncRoot {
            root = u
            dropCount = uncLen
        } else if value.hasPrefix("/") {
            root = "/"
            dropCount = 1
        } else {
            root = ""
            dropCount = 0
        }

        let source = String(value.dropFirst(dropCount))
        let segments: [String]
        if isWindows {
            segments = source.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        } else {
            segments = source.split(separator: Character(separator), omittingEmptySubsequences: true).map(String.init)
        }
        let basename = segments.last ?? value
        if segments.count < 2 {
            let rootWidth = TUIUtil.stringWidth(root)
            if rootWidth >= maxWidth { return takeGraphemes(root, maxWidth: maxWidth, reverse: false) }
            return root + truncateBasename(basename, maxWidth: maxWidth - rootWidth)
        }

        let prefix = "\(root)…\(separator)"
        let basenameWidth = maxWidth - TUIUtil.stringWidth(prefix)
        if basenameWidth <= 0 { return takeGraphemes(prefix, maxWidth: maxWidth, reverse: false) }
        let compact = truncateBasename(basename, maxWidth: basenameWidth)
        if compact != basename { return prefix + compact }

        var selected = [basename]
        let sepWidth = TUIUtil.stringWidth(separator)
        var width = TUIUtil.stringWidth(prefix + basename)
        var idx = segments.count - 2
        while idx >= 0 {
            let segment = segments[idx]
            let next = TUIUtil.stringWidth(segment) + sepWidth
            if width + next > maxWidth {
                let available = maxWidth - width - sepWidth
                if available > 1 {
                    selected.insert(takeGraphemes(segment, maxWidth: available - 1, reverse: false) + "…", at: 0)
                }
                break
            }
            selected.insert(segment, at: 0)
            width += next
            idx -= 1
        }
        return prefix + selected.joined(separator: separator)
    }

    private static func truncateBasename(_ value: String, maxWidth: Int) -> String {
        if TUIUtil.stringWidth(value) <= maxWidth { return value }
        if maxWidth <= 1 { return takeGraphemes("…", maxWidth: maxWidth, reverse: false) }
        if let dot = value.lastIndex(of: "."), dot > value.startIndex {
            let ext = String(value[dot...])
            let extWidth = TUIUtil.stringWidth(ext)
            if extWidth >= maxWidth {
                return "…" + takeGraphemes(ext, maxWidth: maxWidth - 1, reverse: true)
            }
            let stem = String(value[..<dot])
            return takeGraphemes(stem, maxWidth: maxWidth - extWidth - 1, reverse: false) + "…" + ext
        }
        return takeGraphemes(value, maxWidth: maxWidth - 1, reverse: false) + "…"
    }

    private static func takeGraphemes(_ value: String, maxWidth: Int, reverse: Bool) -> String {
        let segs = reverse ? Array(TUIUtil.graphemes(value).reversed()) : TUIUtil.graphemes(value)
        var chosen: [String] = []
        var width = 0
        for seg in segs {
            let next = TUIUtil.stringWidth(seg)
            if width + next > maxWidth { break }
            chosen.append(seg)
            width += next
        }
        if reverse { chosen.reverse() }
        return chosen.joined()
    }

    // MARK: - Links & Session Links (`src/ui/link.tsx`, `src/ui/session-link.ts`)

    // parity: tui/src/ui/link.tsx#LinkProps [status=implemented hash=17a547f7ebae]
    public struct LinkProps: Equatable, Hashable, Sendable {
        public let href: String
        public let label: String?
        public let fg: RGBA?
        public let bg: RGBA?
        public let width: FlexValue?
        public let wrapMode: TextWrapMode?

        public init(
            href: String,
            label: String? = nil,
            fg: RGBA? = nil,
            bg: RGBA? = nil,
            width: FlexValue? = nil,
            wrapMode: TextWrapMode? = nil
        ) {
            self.href = href
            self.label = label
            self.fg = fg
            self.bg = bg
            self.width = width
            self.wrapMode = wrapMode
        }
    }

    /// Renders a clickable OSC-8 hyperlink `TextRenderable` matching `ui/link.tsx#Link`.
    // parity: tui/src/ui/link.tsx#Link [status=adapted hash=3ed92a8cbee7]
    public static func Link(
        ctx: any RenderContext,
        props: LinkProps,
        onOpen: (@Sendable (String) -> Void)? = nil
    ) -> TextRenderable {
        let text = props.label ?? props.href
        let chunk = TextChunk(
            text: text,
            fg: props.fg,
            bg: props.bg,
            attributes: TextAttributes.underline,
            link: TextChunkLink(url: props.href)
        )
        let node = TextRenderable(
            ctx: ctx,
            options: TextOptions(
                content: .styled(StyledText(chunks: [chunk])),
                width: props.width,
                fg: props.fg.map { .rgba($0) },
                bg: props.bg.map { .rgba($0) },
                wrapMode: props.wrapMode
            )
        )
        if let onOpen {
            let href = props.href
            node.onMouseUp = { _ in onOpen(href) }
        }
        return node
    }

    /// Returns whether a mouse release event represents a plain unmodified click inside a cell selection.
    // parity: tui/src/ui/link.tsx#plainClick [status=implemented hash=665e11920107]
    public static func plainClick(renderer: CliRenderer, event: MouseEvent) -> Bool {
        if !event.isDragging || event.modifiers.ctrl || event.modifiers.alt || event.modifiers.shift {
            return false
        }
        guard let selection = renderer.getSelection() else { return false }
        return selection.isStart && selection.behavior == .cell
    }

    /// Resolves the hyperlink URL at the clicked cell on a plain click, matching `ui/link.tsx#clickedLink`.
    // parity: tui/src/ui/link.tsx#clickedLink [status=implemented hash=05dfab4f1c7e]
    public static func clickedLink(renderer: CliRenderer, event: MouseEvent) -> String? {
        guard plainClick(renderer: renderer, event: event) else { return nil }
        let cell = renderer.currentRenderBuffer.getCell(x: event.x, y: event.y)
        guard let cell else { return nil }
        let linkId = getLinkId(cell.attributes)
        guard linkId != 0 else { return nil }
        return try? renderer.currentRenderBuffer.linkPool.get(linkId)
    }

    public struct SessionLinkRange: Equatable, Hashable, Sendable {
        public let start: Int
        public let end: Int
        public let sessionID: String

        public init(start: Int, end: Int, sessionID: String) {
            self.start = start
            self.end = end
            self.sessionID = sessionID
        }
    }

    public struct SessionLinksController: Sendable {
        public let linkify: @Sendable ([TextChunk], Bool, RGBA?) -> (chunks: [TextChunk], ranges: [SessionLinkRange], sessionIDs: Set<String>)
        public let sessionAt: @Sendable (String, [SessionLinkRange], Int, Int) -> String?
        /// The Markdown inline hook: links session IDs in paragraphs and headings, tagging each link span with its
        /// session ID as the span `target`.
        public let linkSpans: @Sendable ([MarkdownInlineSpan], MarkdownInlineContext) -> [MarkdownInlineSpan]
        /// Labels each ID was last rendered with, so a refresh reruns the hook only for blocks whose labels changed.
        private let labels: SessionLinkLabels
        private let labelOf: @Sendable (String) -> String?

        public init(
            linkify: @escaping @Sendable ([TextChunk], Bool, RGBA?) -> (chunks: [TextChunk], ranges: [SessionLinkRange], sessionIDs: Set<String>),
            sessionAt: @escaping @Sendable (String, [SessionLinkRange], Int, Int) -> String?,
            labelOf: @escaping @Sendable (String) -> String? = { _ in nil }
        ) {
            self.linkify = linkify
            self.sessionAt = sessionAt
            self.labelOf = labelOf
            let labels = SessionLinkLabels()
            self.labels = labels
            self.linkSpans = { spans, context in
                linkSessionSpans(spans, context: context, labelOf: labelOf, labels: labels)
            }
        }

        /// Markdown runs the hook only on blocks whose source holds one of these substrings.
        public var inlineHookFilter: [String] { ["ses_"] }

        /// Installs the hook on `markdown` and opens a clicked session link through `open`. The first parse already
        /// runs the hook when this is called before content is set.
        public func attach(
            _ markdown: MarkdownRenderable,
            renderer: CliRenderer,
            dialog: DialogContext? = nil,
            open: @escaping (String) -> Void
        ) {
            let hook = linkSpans
            markdown.inlineHook = { spans, context in hook(spans, context) }
            markdown.inlineHookFilter = inlineHookFilter
            markdown.onMouseUp = { [weak markdown] event in
                guard let markdown, plainClick(renderer: renderer, event: event) else { return }
                guard let sessionID = markdown.targetAt(x: event.x, y: event.y) else { return }
                event.stopPropagation()
                if let dialog, !dialog.stack.isEmpty { dialog.clear() }
                open(sessionID)
            }
        }

        /// Reruns the hook on the blocks that mention a session whose label changed; nothing is parsed again.
        public func refreshLabels(_ markdown: MarkdownRenderable) {
            let changed = labels.changed(labelOf)
            guard !changed.isEmpty else { return }
            markdown.rerunInlineHook { source in changed.contains { source.contains($0) } }
        }
    }

    /// Labels each session ID was last rendered with.
    final class SessionLinkLabels: Sendable {
        private let used = Mutex<[String: String?]>([:])

        func record(_ sessionID: String, _ label: String?) {
            used.withLock { map in
                if map[sessionID] == nil || map[sessionID]! != label { map[sessionID] = .some(label) }
            }
        }

        /// The IDs whose label differs from the one last rendered; records the new labels.
        func changed(_ labelOf: (String) -> String?) -> [String] {
            used.withLock { map in
                var changed: [String] = []
                for (sessionID, label) in map where labelOf(sessionID) != label {
                    changed.append(sessionID)
                }
                for sessionID in changed { map[sessionID] = .some(labelOf(sessionID)) }
                return changed.sorted()
            }
        }
    }

    /// Strips a code span's backtick fence (`` /^`+\s?|\s?`+$/ ``).
    private static func stripCodeFence(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        var leading = 0
        while leading < scalars.count, scalars[leading] == "`" { leading += 1 }
        if leading > 0 {
            scalars.removeFirst(leading)
            if let first = scalars.first, first.properties.isWhitespace { scalars.removeFirst() }
        }
        var trailing = 0
        while trailing < scalars.count, scalars[scalars.count - 1 - trailing] == "`" { trailing += 1 }
        if trailing > 0 {
            scalars.removeLast(trailing)
            if let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Markdown runs this on every paragraph and heading that holds "ses_"; fenced code never gets it.
    static func linkSessionSpans(
        _ spans: [MarkdownInlineSpan],
        context: MarkdownInlineContext,
        labelOf: (String) -> String?,
        labels: SessionLinkLabels
    ) -> [MarkdownInlineSpan] {
        if context.tableCell { return spans }
        let style = context.syntaxStyle.mergeStyles(["markup.link.url"])
        return spans.flatMap { span -> [MarkdownInlineSpan] in
            // Like the web app, a code span links only when it is exactly a session ID, so a command such
            // as `opencode --session ses_…` stays copyable.
            if span.link != nil || (span.code && parseSessionMention(stripCodeFence(span.text)) == nil) { return [span] }
            let mentions = sessionMentions(span.text)
            if mentions.isEmpty { return [span] }
            let units = Array(span.text.utf16)
            // Odd parts are the mentions.
            let cuts = [0] + mentions.flatMap { [$0.start, $0.end] } + [units.count]
            return cuts.dropFirst().enumerated().flatMap { index, end -> [MarkdownInlineSpan] in
                let text = String(decoding: units[cuts[index]..<end], as: UTF16.self)
                let mention = index % 2 == 1 ? mentions[(index - 1) / 2] : nil
                let label = mention.flatMap { labelOf($0.id) }
                if let mention { labels.record(mention.id, label) }
                guard let mention, let label else {
                    if text.isEmpty { return [] }
                    var copy = span
                    copy.text = text
                    return [copy]
                }
                var link = span
                // Raw markdown mode shows the source.
                link.text = context.conceal ? "@\(label)" : text
                link.fg = style.fg ?? span.fg
                link.attributes = style.attributes | TextAttributes.underline
                link.target = mention.id
                return [link]
            }
        }
    }

    /// Creates a session-ID linkifier & click hit-tester for markdown prose blocks, matching `ui/session-link.ts#useSessionLinks`.
    /// ``SessionLinksController/attach(_:renderer:dialog:open:)`` installs the inline hook on a `MarkdownRenderable`;
    /// links carry their session ID as the span target, so a click resolves through `targetAt`.
    // parity: tui/src/ui/session-link.ts#useSessionLinks [status=adapted hash=32090ccd4d9a]
    public static func useSessionLinks(
        currentSessionID: String? = nil,
        resolveLabel: @escaping @Sendable (String) -> String?
    ) -> SessionLinksController {
        SessionLinksController(
            linkify: { chunks, conceal, linkColor in
                var outChunks: [TextChunk] = []
                var ranges: [SessionLinkRange] = []
                var ids = Set<String>()
                var offset = 0

                for chunk in chunks {
                    if chunk.link != nil {
                        outChunks.append(chunk)
                        offset += chunk.text.utf16.count
                        continue
                    }
                    let mentions = sessionMentions(chunk.text)
                    if mentions.isEmpty {
                        outChunks.append(chunk)
                        offset += chunk.text.utf16.count
                        continue
                    }
                    let utf16 = chunk.text.utf16
                    var cursor = 0
                    for mention in mentions {
                        if mention.start > cursor {
                            let sIdx = utf16.index(utf16.startIndex, offsetBy: cursor)
                            let eIdx = utf16.index(utf16.startIndex, offsetBy: mention.start)
                            let slice = String(chunk.text[sIdx..<eIdx])
                            if !slice.isEmpty {
                                outChunks.append(TextChunk(text: slice, fg: chunk.fg, bg: chunk.bg, attributes: chunk.attributes))
                                offset += slice.utf16.count
                            }
                        }
                        let mStart = utf16.index(utf16.startIndex, offsetBy: mention.start)
                        let mEnd = utf16.index(utf16.startIndex, offsetBy: mention.end)
                        let rawText = String(chunk.text[mStart..<mEnd])
                        ids.insert(mention.id)
                        let label: String? = (mention.id == currentSessionID) ? nil : resolveLabel(mention.id)
                        if let label {
                            let rendered = conceal ? "@\(label)" : rawText
                            let linked = TextChunk(
                                text: rendered,
                                fg: linkColor ?? chunk.fg,
                                bg: chunk.bg,
                                attributes: (chunk.attributes ?? 0) | TextAttributes.underline
                            )
                            let startPos = offset
                            offset += rendered.utf16.count
                            outChunks.append(linked)
                            ranges.append(SessionLinkRange(start: startPos, end: offset, sessionID: mention.id))
                        } else if !rawText.isEmpty {
                            outChunks.append(TextChunk(text: rawText, fg: chunk.fg, bg: chunk.bg, attributes: chunk.attributes))
                            offset += rawText.utf16.count
                        }
                        cursor = mention.end
                    }
                    if cursor < utf16.count {
                        let sIdx = utf16.index(utf16.startIndex, offsetBy: cursor)
                        let tail = String(chunk.text[sIdx...])
                        if !tail.isEmpty {
                            outChunks.append(TextChunk(text: tail, fg: chunk.fg, bg: chunk.bg, attributes: chunk.attributes))
                            offset += tail.utf16.count
                        }
                    }
                }
                return (outChunks, ranges, ids)
            },
            sessionAt: { fullText, ranges, line, column in
                let lines = fullText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                guard line >= 0 && line < lines.count else { return nil }
                let lineStart = lines.prefix(line).reduce(0) { $0 + $1.utf16.count + 1 }
                let lineEnd = lineStart + lines[line].utf16.count
                let utf16 = fullText.utf16
                for range in ranges where range.start >= lineStart && range.end <= lineEnd {
                    let s0 = utf16.index(utf16.startIndex, offsetBy: lineStart)
                    let s1 = utf16.index(utf16.startIndex, offsetBy: range.start)
                    let s2 = utf16.index(utf16.startIndex, offsetBy: range.end)
                    let startCol = TUIUtil.stringWidth(String(fullText[s0..<s1]))
                    let spanWidth = TUIUtil.stringWidth(String(fullText[s1..<s2]))
                    if column >= startCol && column < startCol + spanWidth {
                        return range.sessionID
                    }
                }
                return nil
            },
            labelOf: { id in id == currentSessionID ? nil : resolveLabel(id) }
        )
    }

    // MARK: - Pane Resize (`src/ui/pane-resize.ts`, `src/ui/pane-resize-handle.tsx`)

    public final class PaneResizeController: Sendable {
        private struct State: Sendable {
            var preferredSize: Int
            var requestedSize: Int
            var hovered: Bool = false
            var resizing: Bool = false
            var moved: Bool = false
            var lastBoundaryClickMs: Double = 0
        }

        private let defaultValueProvider: @Sendable () -> Int
        private let clampFn: @Sendable (Int) -> Int
        private let fromMouseFn: @Sendable (MouseEvent) -> Int
        private let containsFn: @Sendable (MouseEvent, Int) -> Bool
        private let onCommitFn: @Sendable (Int) -> Void
        private let nowProvider: @Sendable () -> Double
        private let state: Mutex<State>

        public init(
            initialValue: Int,
            defaultValue: @escaping @Sendable () -> Int,
            clamp: @escaping @Sendable (Int) -> Int,
            fromMouse: @escaping @Sendable (MouseEvent) -> Int,
            contains: @escaping @Sendable (MouseEvent, Int) -> Bool,
            onCommit: @escaping @Sendable (Int) -> Void,
            now: (@Sendable () -> Double)? = nil
        ) {
            self.defaultValueProvider = defaultValue
            self.clampFn = clamp
            self.fromMouseFn = fromMouse
            self.containsFn = contains
            self.onCommitFn = onCommit
            self.nowProvider = now ?? { Date().timeIntervalSinceReferenceDate * 1000.0 }
            self.state = Mutex(State(preferredSize: initialValue, requestedSize: initialValue))
        }

        public var preferredSize: Int { state.withLock { $0.preferredSize } }
        public var size: Int { clampFn(preferredSize) }
        public var hovered: Bool { state.withLock { $0.hovered } }
        public var resizing: Bool { state.withLock { $0.resizing } }

        public func syncValue(_ externalValue: Int) {
            state.withLock { s in
                if s.resizing { return }
                s.requestedSize = externalValue
                s.preferredSize = externalValue
            }
        }

        public func onMouseOver() { state.withLock { $0.hovered = true } }
        public func onMouseOut() { state.withLock { $0.hovered = false } }

        public func onMouseDown(_ event: MouseEvent) {
            guard event.button == MockMouseButtons.left else { return }
            let now = nowProvider()
            var committed: Int? = nil
            state.withLock { s in
                if now - s.lastBoundaryClickMs < 300 {
                    s.lastBoundaryClickMs = 0
                    s.resizing = false
                    s.hovered = false
                    let next = clampFn(defaultValueProvider())
                    s.preferredSize = next
                    if s.requestedSize != next {
                        s.requestedSize = next
                        committed = next
                    }
                    return
                }
                s.moved = false
                s.resizing = true
            }
            if let committed { onCommitFn(committed) }
            event.preventDefault()
            event.stopPropagation()
        }

        public func onMouseDrag(_ event: MouseEvent) {
            let next = clampFn(fromMouseFn(event))
            let wasResizing = state.withLock { s -> Bool in
                guard s.resizing else { return false }
                s.moved = true
                s.lastBoundaryClickMs = 0
                s.preferredSize = next
                return true
            }
            if wasResizing { event.stopPropagation() }
        }

        public func finish(_ event: MouseEvent) {
            let now = nowProvider()
            var committed: Int? = nil
            let wasResizing = state.withLock { s -> Bool in
                guard s.resizing else { return false }
                let rawNext = s.moved ? fromMouseFn(event) : clampFn(s.preferredSize)
                let next = clampFn(rawNext)
                s.resizing = false
                s.lastBoundaryClickMs = s.moved ? 0 : now
                s.preferredSize = next
                if s.requestedSize != next {
                    s.requestedSize = next
                    committed = next
                }
                s.hovered = containsFn(event, next)
                return true
            }
            if let committed { onCommitFn(committed) }
            if wasResizing { event.stopPropagation() }
        }
    }

    // parity: tui/src/ui/pane-resize.ts#createPaneResize [status=adapted hash=e55973aa855a]
    public static func createPaneResize(
        initialValue: Int,
        defaultValue: @escaping @Sendable () -> Int,
        clamp: @escaping @Sendable (Int) -> Int,
        fromMouse: @escaping @Sendable (MouseEvent) -> Int,
        contains: @escaping @Sendable (MouseEvent, Int) -> Bool,
        onCommit: @escaping @Sendable (Int) -> Void,
        now: (@Sendable () -> Double)? = nil
    ) -> PaneResizeController {
        PaneResizeController(
            initialValue: initialValue,
            defaultValue: defaultValue,
            clamp: clamp,
            fromMouse: fromMouse,
            contains: contains,
            onCommit: onCommit,
            now: now
        )
    }

    public enum PaneResizeHighlight: String, Equatable, Hashable, Sendable {
        case left
        case right
    }

    /// Renders a 2-column vertical pane resize handle into a `BoxRenderable`.
    // parity: tui/src/ui/pane-resize-handle.tsx#PaneResizeHandle [status=adapted hash=20b4bce644b3]
    public static func PaneResizeHandle(
        ctx: any RenderContext,
        resize: PaneResizeController,
        left: Int,
        highlight: PaneResizeHighlight = .left,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let outer = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                width: .point(2),
                height: .percent(100),
                position: .absolute,
                top: .point(0),
                left: .point(Float(left)),
                zIndex: 10,
                onMouseDown: { resize.onMouseDown($0) },
                onMouseOver: { _ in resize.onMouseOver() },
                onMouseOut: { _ in resize.onMouseOut() }
            )
        )
        let active = resize.hovered || resize.resizing
        let line = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                width: .point(1),
                height: .percent(100),
                marginLeft: .point(highlight == .right ? 1 : 0),
                backgroundColor: active ? .rgba(theme.background.raised.high) : nil
            )
        )
        outer.add(line)
        return outer
    }

    // MARK: - Toast (`src/ui/toast.tsx`)

    public enum ToastVariant: String, Equatable, Hashable, Sendable {
        case info
        case success
        case warning
        case error

        public var feedbackKind: FeedbackKind {
            switch self {
            case .info: return .info
            case .success: return .success
            case .warning: return .warning
            case .error: return .error
            }
        }
    }

    public struct ToastAction: Sendable {
        public let label: String
        public let run: @Sendable () -> Void

        public init(label: String, run: @escaping @Sendable () -> Void) {
            self.label = label
            self.run = run
        }
    }

    // parity: tui/src/ui/toast.tsx#ToastOptions [status=implemented hash=c978c2123956]
    public struct ToastOptions: Sendable {
        public var title: String?
        public var message: String
        public var variant: ToastVariant
        public var duration: Int
        public var action: ToastAction?

        public init(
            title: String? = nil,
            message: String,
            variant: ToastVariant = .info,
            duration: Int = 5000,
            action: ToastAction? = nil
        ) {
            self.title = title
            self.message = message
            self.variant = variant
            self.duration = duration
            self.action = action
        }
    }

    /// Stateful toast notification queue controller matching `ui/toast.tsx#ToastContext`.
    // parity: tui/src/ui/toast.tsx#ToastContext [status=adapted hash=0a5e046d8f22]
    public final class ToastContext: Sendable {
        private struct State: Sendable {
            var currentToast: ToastOptions? = nil
            var queue: [ToastOptions] = []
            var paused: Bool = false
            var startedAtMs: Double = 0
            var remainingMs: Double = 0
        }

        private let nowProvider: @Sendable () -> Double
        private let state: Mutex<State>

        public init(now: (@Sendable () -> Double)? = nil) {
            self.nowProvider = now ?? { Date().timeIntervalSinceReferenceDate * 1000.0 }
            self.state = Mutex(State())
        }

        public var currentToast: ToastOptions? {
            state.withLock { $0.currentToast }
        }

        public var pending: Int {
            state.withLock { $0.queue.count }
        }

        public var isPaused: Bool {
            state.withLock { $0.paused }
        }

        public func show(_ options: ToastOptions) {
            let now = nowProvider()
            state.withLock { s in
                if s.currentToast != nil && (s.paused || !s.queue.isEmpty) {
                    s.queue.append(options)
                    return
                }
                s.currentToast = options
                s.startedAtMs = now
                s.remainingMs = Double(options.duration)
            }
        }

        public func error(_ err: any Error) {
            show(ToastOptions(message: TUIUtil.errorMessage(err), variant: .error))
        }

        public func error(message: String) {
            show(ToastOptions(message: message, variant: .error))
        }

        public func pause() {
            let now = nowProvider()
            state.withLock { s in
                guard s.currentToast != nil, !s.paused else { return }
                s.paused = true
                s.remainingMs = max(0, s.remainingMs - (now - s.startedAtMs))
            }
        }

        public func resume() {
            let now = nowProvider()
            state.withLock { s in
                guard s.currentToast != nil, s.paused else { return }
                s.paused = false
                s.startedAtMs = now
            }
        }

        public func dismiss() {
            let now = nowProvider()
            state.withLock { s in
                if s.queue.isEmpty {
                    s.currentToast = nil
                    s.paused = false
                    s.remainingMs = 0
                    return
                }
                let next = s.queue.removeFirst()
                s.currentToast = next
                s.remainingMs = Double(next.duration)
                if !s.paused {
                    s.startedAtMs = now
                }
            }
        }

        /// Advances expiration timer deterministically (for headless / test rendering).
        public func tick(nowMs: Double? = nil) {
            let now = nowMs ?? nowProvider()
            let shouldDismiss = state.withLock { s -> Bool in
                guard s.currentToast != nil, !s.paused else { return false }
                return (now - s.startedAtMs) >= s.remainingMs
            }
            if shouldDismiss { dismiss() }
        }

        public func activate() {
            let action = state.withLock { $0.currentToast?.action }
            dismiss()
            action?.run()
        }
    }

    private static let activeToastContext = Mutex<ToastContext?>(nil)

    /// Installs a `ToastContext` provider scope matching `ui/toast.tsx#ToastProvider`.
    // parity: tui/src/ui/toast.tsx#ToastProvider [status=adapted hash=f065bb9c3fbf]
    public static func ToastProvider(
        context: ToastContext = ToastContext(),
        body: (ToastContext) -> BoxRenderable
    ) -> BoxRenderable {
        activeToastContext.withLock { $0 = context }
        return body(context)
    }

    /// Reads the active `ToastContext` matching `ui/toast.tsx#useToast`.
    // parity: tui/src/ui/toast.tsx#useToast [status=adapted hash=e9787480a431]
    public static func useToast() -> ToastContext {
        if let existing = activeToastContext.withLock({ $0 }) {
            return existing
        }
        let created = ToastContext()
        activeToastContext.withLock { $0 = created }
        return created
    }

    /// Renders the active toast banner into a `BoxRenderable` (or `nil` when idle), matching `ui/toast.tsx#Toast`.
    // parity: tui/src/ui/toast.tsx#Toast [status=adapted hash=b756961873e9]
    public static func Toast(
        ctx: any RenderContext,
        toast: ToastContext,
        theme: ResolvedTheme,
        terminalWidth: Int = 80
    ) -> BoxRenderable? {
        guard let current = toast.currentToast else { return nil }
        let borderColor = theme.text.feedback[current.variant.feedbackKind].base
        let outer = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "tui-toast",
                maxWidth: .point(Float(max(12, min(60, terminalWidth - 6)))),
                alignItems: .flexStart,
                justifyContent: .center,
                position: .absolute,
                top: .point(1),
                right: .point(2),
                onMouseUp: { _ in toast.activate() },
                onMouseOver: { _ in toast.pause() },
                onMouseOut: { _ in toast.resume() },
                border: .sides(SplitBorder.border),
                borderColor: .rgba(borderColor),
                customBorderChars: SplitBorder.customBorderChars
            )
        )
        let inner = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                width: .percent(100),
                flexDirection: .column,
                paddingTop: .point(1),
                paddingRight: .point(2),
                paddingBottom: .point(1),
                paddingLeft: .point(2),
                backgroundColor: .rgba(theme.background.raised.high)
            )
        )
        let affordanceText = current.action.map { "› \($0.label)" } ?? "x"
        if let title = current.title {
            let headerRow = BoxRenderable(
                ctx: ctx,
                options: BoxOptions(width: .percent(100), flexDirection: .row, justifyContent: .spaceBetween, marginBottom: .point(1))
            )
            headerRow.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(title), fg: .rgba(theme.text.base), attributes: TextAttributes.bold)))
            headerRow.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(affordanceText), fg: .rgba(theme.text.muted))))
            inner.add(headerRow)
            inner.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(current.message), width: .percent(100), fg: .rgba(theme.text.base), wrapMode: .word)))
        } else {
            let row = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .row, justifyContent: .spaceBetween, gap: .point(2)))
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(current.message), flexGrow: 1, fg: .rgba(theme.text.base), wrapMode: .word)))
            row.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(affordanceText), fg: .rgba(theme.text.muted))))
            inner.add(row)
        }
        if toast.pending > 0 {
            inner.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("+\(toast.pending) more"), fg: .rgba(theme.text.muted))))
        }
        outer.add(inner)
        return outer
    }

    // MARK: - Dialog Frame, Stack, Header, Layout, Buttons & Footer (`src/ui/dialog.tsx`)

    // parity: tui/src/ui/dialog.tsx#DialogSize [status=implemented hash=ea7c2ff6a00a]
    public enum DialogSize: String, Equatable, Hashable, Sendable, CaseIterable {
        case medium
        case large
        case xlarge
    }

    // parity: tui/src/ui/dialog.tsx#DIALOG_INSET [status=implemented hash=0ff90acf06bf]
    public static let DIALOG_INSET = 3

    // parity: tui/src/ui/dialog.tsx#DIALOG_LIST_INSET [status=implemented hash=de6661520293]
    public static let DIALOG_LIST_INSET = DIALOG_INSET + 1

    // parity: tui/src/ui/dialog.tsx#dialogWidth [status=implemented hash=99027221e416]
    public static func dialogWidth(_ size: DialogSize) -> Int {
        switch size {
        case .xlarge: return 116
        case .large: return 88
        case .medium: return 60
        }
    }

    // parity: tui/src/ui/dialog.tsx#DialogButton [status=implemented hash=07809ced5eb7]
    public struct DialogButton: Sendable {
        public let label: String
        public let run: @Sendable () -> Void

        public init(label: String, run: @escaping @Sendable () -> Void) {
            self.label = label
            self.run = run
        }
    }

    // parity: tui/src/ui/dialog.tsx#DialogFooterAction [status=implemented hash=abd0fcaa198b]
    public struct DialogFooterAction: Sendable {
        public var title: String
        public var key: String?
        public var command: String?
        public var onTrigger: (@Sendable () -> Void)?
        public var disabled: Bool
        public var color: RGBA?

        public init(
            title: String,
            key: String? = nil,
            command: String? = nil,
            onTrigger: (@Sendable () -> Void)? = nil,
            disabled: Bool = false,
            color: RGBA? = nil
        ) {
            self.title = title
            self.key = key
            self.command = command
            self.onTrigger = onTrigger
            self.disabled = disabled
            self.color = color
        }
    }

    // parity: tui/src/ui/dialog.tsx#DialogFooterActions [status=implemented hash=54e055480e91]
    public struct DialogFooterActions: Sendable {
        public var secondary: [DialogFooterAction]
        public var primary: [DialogFooterAction]

        public init(secondary: [DialogFooterAction] = [], primary: [DialogFooterAction] = []) {
            self.secondary = secondary
            self.primary = primary
        }
    }

    // parity: tui/src/ui/dialog.tsx#DialogFooterProps [status=implemented hash=139cd0f2eec6]
    public struct DialogFooterProps: Sendable {
        public var actions: DialogFooterActions?
        public var inset: Int?
        public var text: String?

        public init(actions: DialogFooterActions? = nil, inset: Int? = nil, text: String? = nil) {
            self.actions = actions
            self.inset = inset
            self.text = text
        }
    }

    public struct DialogStackEntry: Sendable {
        public let key: String?
        public let render: @Sendable (any RenderContext) -> BoxRenderable
        public let onClose: (@Sendable () -> Void)?

        public init(
            key: String? = nil,
            render: @escaping @Sendable (any RenderContext) -> BoxRenderable,
            onClose: (@Sendable () -> Void)? = nil
        ) {
            self.key = key
            self.render = render
            self.onClose = onClose
        }
    }

    /// Modal dialog stack controller matching `ui/dialog.tsx#DialogContext`.
    // parity: tui/src/ui/dialog.tsx#DialogContext [status=adapted hash=1c79d2748d62]
    public final class DialogContext: Sendable {
        private struct State: Sendable {
            var stack: [DialogStackEntry] = []
            var size: DialogSize = .medium
            var centered: Bool = false
        }

        private let state = Mutex(State())

        public init() {}

        public var stack: [DialogStackEntry] { state.withLock { $0.stack } }
        public var size: DialogSize { state.withLock { $0.size } }
        public var centered: Bool { state.withLock { $0.centered } }
        public var key: String? { state.withLock { $0.stack.last?.key } }
        public var isOpen: Bool { state.withLock { !$0.stack.isEmpty } }

        public func setSize(_ size: DialogSize) {
            state.withLock { $0.size = size }
        }

        public func setCentered(_ centered: Bool) {
            state.withLock { $0.centered = centered }
        }

        public func clear() {
            let closers = state.withLock { s -> [@Sendable () -> Void] in
                let callbacks = s.stack.compactMap(\.onClose)
                s.size = .medium
                s.centered = false
                s.stack.removeAll()
                return callbacks
            }
            for cb in closers { cb() }
        }

        public func pop() {
            let closer = state.withLock { s -> (@Sendable () -> Void)? in
                guard let last = s.stack.popLast() else { return nil }
                if s.stack.isEmpty {
                    s.size = .medium
                    s.centered = false
                }
                return last.onClose
            }
            closer?()
        }

        public func replace(
            key: String? = nil,
            size: DialogSize = .medium,
            onClose: (@Sendable () -> Void)? = nil,
            render: @escaping @Sendable (any RenderContext) -> BoxRenderable
        ) {
            let previous = state.withLock { s -> [@Sendable () -> Void] in
                let callbacks = s.stack.compactMap(\.onClose)
                s.size = size
                s.centered = false
                s.stack = [DialogStackEntry(key: key, render: render, onClose: onClose)]
                return callbacks
            }
            for cb in previous { cb() }
        }
    }

    private static let activeDialogContext = Mutex<DialogContext?>(nil)

    /// Installs a `DialogContext` scope and renders active modal dialogs above children.
    // parity: tui/src/ui/dialog.tsx#DialogProvider [status=adapted hash=0b3c4a46a35f]
    public static func DialogProvider(
        ctx: any RenderContext,
        context: DialogContext = DialogContext(),
        theme: ResolvedTheme,
        terminalWidth: Int = 80,
        terminalHeight: Int = 24,
        content: (DialogContext) -> Renderable
    ) -> BoxRenderable {
        activeDialogContext.withLock { $0 = context }
        let root = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(width: .point(Float(terminalWidth)), height: .point(Float(terminalHeight)))
        )
        root.add(content(context))
        if let entry = context.stack.last {
            let modal = Dialog(
                ctx: ctx,
                size: context.size,
                centered: context.centered,
                theme: theme,
                terminalWidth: terminalWidth,
                terminalHeight: terminalHeight,
                onClose: { context.clear() },
                body: entry.render(ctx)
            )
            root.add(modal)
        }
        return root
    }

    // parity: tui/src/ui/dialog.tsx#useDialog [status=adapted hash=3af9e7da9ca4]
    public static func useDialog() -> DialogContext {
        if let existing = activeDialogContext.withLock({ $0 }) {
            return existing
        }
        let created = DialogContext()
        activeDialogContext.withLock { $0 = created }
        return created
    }

    /// Renders a centered modal backdrop and dialog panel surface into a `BoxRenderable`.
    // parity: tui/src/ui/dialog.tsx#Dialog [status=adapted hash=2d9be53cbc58]
    public static func Dialog(
        ctx: any RenderContext,
        size: DialogSize = .medium,
        centered: Bool = false,
        theme: ResolvedTheme,
        terminalWidth: Int = 80,
        terminalHeight: Int = 24,
        onClose: (@Sendable () -> Void)? = nil,
        body: Renderable
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let backdrop = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "tui-dialog-backdrop",
                width: .point(Float(terminalWidth)),
                height: .point(Float(terminalHeight)),
                alignItems: .center,
                justifyContent: centered ? .center : .flexStart,
                position: .absolute,
                top: .point(0),
                left: .point(0),
                paddingTop: .point(centered ? Float(0) : Float(terminalHeight / 4)),
                zIndex: 3000,
                onMouseUp: { _ in onClose?() },
                backgroundColor: .rgba(RGBA.fromInts(0, 0, 0, 150))
            )
        )
        let panelWidth = min(dialogWidth(size), max(10, terminalWidth - 2))
        let panel = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: "tui-dialog-panel",
                width: .point(Float(panelWidth)),
                paddingTop: .point(1),
                onMouseUp: { $0.stopPropagation() },
                backgroundColor: .rgba(surface.background.base)
            )
        )
        panel.add(body)
        backdrop.add(panel)
        return backdrop
    }

    /// Renders a dialog title header bar with `esc` close affordance and optional description.
    // parity: tui/src/ui/dialog.tsx#DialogHeader [status=adapted hash=7075984f4d42]
    public static func DialogHeader(
        ctx: any RenderContext,
        title: String,
        description: String? = nil,
        closeLabel: String = "esc",
        theme: ResolvedTheme,
        newDesigns: Bool = false,
        onClose: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let row = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(width: .percent(100), flexDirection: .row, justifyContent: .spaceBetween, gap: .point(1))
        )
        row.add(
            TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    content: .string(title),
                    fg: .rgba(surface.text.base),
                    attributes: newDesigns ? TextAttributes.none : TextAttributes.bold
                )
            )
        )
        let close = TextRenderable(
            ctx: ctx,
            options: TextOptions(content: .string(closeLabel), fg: .rgba(surface.text.muted))
        )
        if let onClose {
            close.onMouseUp = { _ in onClose() }
        }
        row.add(close)

        if let description, !description.isEmpty {
            let wrapper = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column))
            wrapper.add(row)
            wrapper.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(description), fg: .rgba(surface.text.muted), wrapMode: .word)))
            return wrapper
        }
        return row
    }

    /// Standard dialog vertical layout container: header, body, and buttons or footer.
    /// With `grow`, the layout fills the parent's height and keeps the footer at the bottom.
    // parity: tui/src/ui/dialog.tsx#DialogLayout [status=adapted hash=e30075c0f3a9]
    public static func DialogLayout(
        ctx: any RenderContext,
        id: String? = nil,
        header: Renderable,
        body: Renderable,
        buttons: Renderable? = nil,
        footer: Renderable? = nil,
        inset: Int = DIALOG_INSET,
        grow: Bool = false
    ) -> BoxRenderable {
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                id: id,
                width: .percent(100),
                flexGrow: grow ? 1 : nil,
                flexDirection: .column,
                paddingRight: .point(Float(inset)),
                paddingBottom: .point(1),
                paddingLeft: .point(Float(inset)),
                gap: .point(1)
            )
        )
        box.add(header)
        if grow {
            let content = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexGrow: 1, flexDirection: .column))
            content.add(body)
            box.add(content)
        } else {
            box.add(body)
        }
        if let buttons {
            box.add(buttons)
        } else if let footer {
            box.add(footer)
        }
        return box
    }

    /// Right-aligned interactive dialog button strip matching `ui/dialog.tsx#DialogButtons`. `hints` are extra key
    /// actions shown on the left; a hint without a key takes its command's shortcut, and is dropped without one.
    // parity: tui/src/ui/dialog.tsx#DialogButtons [status=adapted hash=5c3b51860d51]
    public static func DialogButtons(
        ctx: any RenderContext,
        buttons: [DialogButton],
        active: Int,
        theme: ResolvedTheme,
        hints: [DialogFooterAction] = [],
        shortcut: ((String) -> String?)? = nil,
        onActive: (@Sendable (Int) -> Void)? = nil
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let resolvedHints = hints.flatMap { action -> [DialogFooterAction] in
            guard action.key == nil, let command = action.command else { return [action] }
            guard let key = shortcut?(command), !key.isEmpty else { return [] }
            var copy = action
            copy.key = key
            return [copy]
        }
        let row = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                width: .percent(100),
                flexDirection: .row,
                justifyContent: resolvedHints.isEmpty ? .flexEnd : .spaceBetween
            )
        )
        if !resolvedHints.isEmpty {
            // Hint items pad one cell for hover, so pull them back to line up with the body.
            let hintGroup = BoxRenderable(ctx: ctx, options: BoxOptions(flexDirection: .row, marginLeft: .point(-1)))
            for action in resolvedHints {
                let item = BoxRenderable(ctx: ctx, options: BoxOptions(paddingRight: .point(1), paddingLeft: .point(1)))
                item.add(renderFooterAction(ctx: ctx, action: action, surface: surface))
                hintGroup.add(item)
            }
            row.add(hintGroup)
        }
        let buttonGroup = BoxRenderable(ctx: ctx, options: BoxOptions(flexDirection: .row, gap: .point(1)))
        for (idx, button) in buttons.enumerated() {
            let isActive = idx == active
            let btn = BoxRenderable(
                ctx: ctx,
                options: BoxOptions(
                    paddingRight: .point(1),
                    paddingLeft: .point(1),
                    onMouseUp: { _ in button.run() },
                    onMouseOver: onActive.map { handler in { _ in handler(idx) } },
                    backgroundColor: isActive ? .rgba(surface.background.action.primary.focused) : nil
                )
            )
            btn.add(
                TextRenderable(
                    ctx: ctx,
                    options: TextOptions(
                        content: .string(button.label),
                        fg: .rgba(isActive ? surface.text.action.primary.focused : surface.text.muted)
                    )
                )
            )
            buttonGroup.add(btn)
        }
        row.add(buttonGroup)
        return row
    }

    /// Full-bleed wrapper canceling horizontal `DIALOG_INSET` margins inside `DialogLayout`.
    // parity: tui/src/ui/dialog.tsx#DialogBleed [status=adapted hash=fe76cdd3a7b3]
    public static func DialogBleed(
        ctx: any RenderContext,
        children: [Renderable]
    ) -> BoxRenderable {
        let box = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                width: .percent(100),
                flexDirection: .column,
                marginRight: .point(Float(-DIALOG_INSET)),
                marginLeft: .point(Float(-DIALOG_INSET))
            )
        )
        for child in children { box.add(child) }
        return box
    }

    /// Renders a dialog footer band with left-aligned secondary actions and right-aligned primary actions.
    // parity: tui/src/ui/dialog.tsx#DialogFooter [status=adapted hash=03934346b67a]
    public static func DialogFooter(
        ctx: any RenderContext,
        props: DialogFooterProps,
        theme: ResolvedTheme,
        newDesigns: Bool = false
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let secondary = props.actions?.secondary ?? []
        let primary = props.actions?.primary ?? []
        let hasBand = newDesigns && (!secondary.isEmpty || !primary.isEmpty || props.text != nil)
        let row = BoxRenderable(
            ctx: ctx,
            options: BoxOptions(
                width: .percent(100),
                flexDirection: .row,
                justifyContent: .spaceBetween,
                paddingTop: hasBand ? .point(1) : nil,
                paddingRight: props.inset.map { .point(Float($0)) },
                paddingBottom: hasBand ? .point(1) : nil,
                paddingLeft: props.inset.map { .point(Float($0)) },
                gap: .point(2),
                backgroundColor: hasBand ? .rgba(surface.background.raised.high) : nil
            )
        )
        let leftGroup = BoxRenderable(ctx: ctx, options: BoxOptions(flexDirection: .row, gap: .point(2)))
        if let text = props.text, !text.isEmpty {
            leftGroup.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(text), fg: .rgba(surface.text.muted))))
        }
        for action in secondary {
            leftGroup.add(renderFooterAction(ctx: ctx, action: action, surface: surface))
        }
        let rightGroup = BoxRenderable(ctx: ctx, options: BoxOptions(flexDirection: .row, gap: .point(2)))
        for action in primary {
            rightGroup.add(renderFooterAction(ctx: ctx, action: action, surface: surface))
        }
        row.add(leftGroup)
        row.add(rightGroup)
        return row
    }

    private static func renderFooterAction(
        ctx: any RenderContext,
        action: DialogFooterAction,
        surface: ResolvedTheme
    ) -> TextRenderable {
        let titleColor = action.disabled ? surface.text.action.primary.disabled : (action.color ?? surface.text.base)
        let keyColor = action.disabled ? surface.text.action.primary.disabled : (action.color ?? surface.text.muted)
        var chunks = [TextChunk(text: action.title, fg: titleColor)]
        if let key = action.key, !key.isEmpty {
            chunks.append(TextChunk(text: " \(key)", fg: keyColor))
        }
        let text = TextRenderable(ctx: ctx, options: TextOptions(content: .styled(StyledText(chunks: chunks))))
        if !action.disabled, let trigger = action.onTrigger {
            text.onMouseUp = { _ in trigger() }
        }
        return text
    }

    // MARK: - Dialog Alert, Confirm, Help, Export, Prompt, Select

    // parity: tui/src/ui/dialog-alert.tsx#DialogAlertProps [status=implemented hash=4c6eca494f13]
    public struct DialogAlertProps: Sendable {
        public let title: String
        public let message: String
        public let onConfirm: (@Sendable () -> Void)?

        public init(title: String, message: String, onConfirm: (@Sendable () -> Void)? = nil) {
            self.title = title
            self.message = message
            self.onConfirm = onConfirm
        }
    }

    // parity: tui/src/ui/dialog-alert.tsx#DialogAlert [status=adapted hash=2ab650315cb3]
    public static func DialogAlert(
        ctx: any RenderContext,
        props: DialogAlertProps,
        dialog: DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let confirm: @Sendable () -> Void = {
            props.onConfirm?()
            dialog.clear()
        }
        return DialogLayout(
            ctx: ctx,
            id: "dialog-alert",
            header: DialogHeader(ctx: ctx, title: props.title, theme: theme, onClose: confirm),
            body: TextRenderable(ctx: ctx, options: TextOptions(content: .string(props.message), fg: .rgba(surface.text.muted), wrapMode: .word)),
            footer: DialogFooter(
                ctx: ctx,
                props: DialogFooterProps(actions: DialogFooterActions(primary: [DialogFooterAction(title: "ok", key: "enter", onTrigger: confirm)])),
                theme: theme
            )
        )
    }

    // parity: tui/src/ui/dialog-confirm.tsx#DialogConfirmProps [status=implemented hash=a962c763effc]
    public struct DialogConfirmProps: Sendable {
        public let title: String
        public let message: String
        public let confirmLabel: String
        public let cancelLabel: String
        public let onConfirm: (@Sendable () -> Void)?
        public let onCancel: (@Sendable () -> Void)?

        public init(
            title: String,
            message: String,
            confirmLabel: String = "Confirm",
            cancelLabel: String = "Cancel",
            onConfirm: (@Sendable () -> Void)? = nil,
            onCancel: (@Sendable () -> Void)? = nil
        ) {
            self.title = title
            self.message = message
            self.confirmLabel = confirmLabel
            self.cancelLabel = cancelLabel
            self.onConfirm = onConfirm
            self.onCancel = onCancel
        }
    }

    // parity: tui/src/ui/dialog-confirm.tsx#DialogConfirm [status=adapted hash=40e52150864d]
    public static func DialogConfirm(
        ctx: any RenderContext,
        props: DialogConfirmProps,
        dialog: DialogContext,
        theme: ResolvedTheme,
        activeIndex: Int = 1
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let buttons = [
            DialogButton(label: TUIUtil.titlecase(props.cancelLabel)) {
                props.onCancel?()
                dialog.clear()
            },
            DialogButton(label: TUIUtil.titlecase(props.confirmLabel)) {
                props.onConfirm?()
                dialog.clear()
            },
        ]
        return DialogLayout(
            ctx: ctx,
            id: "dialog-confirm",
            header: DialogHeader(ctx: ctx, title: props.title, theme: theme, onClose: {
                props.onCancel?()
                dialog.clear()
            }),
            body: TextRenderable(ctx: ctx, options: TextOptions(content: .string(props.message), fg: .rgba(surface.text.muted), wrapMode: .word)),
            buttons: DialogButtons(ctx: ctx, buttons: buttons, active: activeIndex, theme: theme)
        )
    }

    // parity: tui/src/ui/dialog-export-options.tsx#ExportFormat [status=implemented hash=9f586161a09e]
    public enum ExportFormat: String, Equatable, Hashable, Sendable, CaseIterable {
        case markdown
        case json
    }

    // parity: tui/src/ui/dialog-export-options.tsx#ExportLocation [status=implemented hash=f9696ff6f9e3]
    public enum ExportLocation: String, Equatable, Hashable, Sendable, CaseIterable {
        case project
        case temp
    }

    public struct ExportOptionsSelection: Equatable, Hashable, Sendable {
        public let action: String
        public let format: ExportFormat
        public let location: ExportLocation?
        public let thinking: Bool
        public let tools: Bool
        public let sanitize: Bool

        public init(
            action: String,
            format: ExportFormat,
            location: ExportLocation? = .project,
            thinking: Bool,
            tools: Bool,
            sanitize: Bool
        ) {
            self.action = action
            self.format = format
            self.location = location
            self.thinking = thinking
            self.tools = tools
            self.sanitize = sanitize
        }
    }

    // parity: tui/src/ui/dialog-export-options.tsx#DialogExportOptionsProps [status=implemented hash=f299e0a15b37]
    public struct DialogExportOptionsProps: Sendable {
        public let defaultThinking: Bool
        public let format: ExportFormat
        public let location: ExportLocation
        public let tools: Bool
        public let sanitize: Bool
        public let onConfirm: (@Sendable (ExportOptionsSelection) -> Void)?
        public let onCancel: (@Sendable () -> Void)?

        public init(
            defaultThinking: Bool = false,
            format: ExportFormat = .markdown,
            location: ExportLocation = .project,
            tools: Bool = true,
            sanitize: Bool = false,
            onConfirm: (@Sendable (ExportOptionsSelection) -> Void)? = nil,
            onCancel: (@Sendable () -> Void)? = nil
        ) {
            self.defaultThinking = defaultThinking
            self.format = format
            self.location = location
            self.tools = tools
            self.sanitize = sanitize
            self.onConfirm = onConfirm
            self.onCancel = onCancel
        }
    }

    // parity: tui/src/ui/dialog-export-options.tsx#DialogExportOptions [status=adapted hash=565ac2ba5b51]
    public static func DialogExportOptions(
        ctx: any RenderContext,
        props: DialogExportOptionsProps,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column, gap: .point(1)))
        body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("Format: \(props.format.rawValue) (\(props.location.rawValue))"), fg: .rgba(surface.text.base))))
        if props.format == .markdown {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(props.defaultThinking ? "[x]" : "[ ]") Include thinking"), fg: .rgba(surface.text.muted))))
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(props.tools ? "[x]" : "[ ]") Include tools"), fg: .rgba(surface.text.muted))))
        } else {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string("\(props.sanitize ? "[x]" : "[ ]") Sanitize sensitive data"), fg: .rgba(surface.text.muted))))
        }
        return DialogLayout(
            ctx: ctx,
            id: "dialog-export-options",
            header: DialogHeader(ctx: ctx, title: "Export session", theme: theme, onClose: props.onCancel),
            body: body,
            footer: DialogFooter(
                ctx: ctx,
                props: DialogFooterProps(
                    actions: DialogFooterActions(
                        primary: [
                            DialogFooterAction(title: "copy", key: "c") {
                                props.onConfirm?(ExportOptionsSelection(action: "copy", format: props.format, location: props.location, thinking: props.defaultThinking, tools: props.tools, sanitize: props.sanitize))
                            },
                            DialogFooterAction(title: "save to file", key: "enter") {
                                props.onConfirm?(ExportOptionsSelection(action: "export", format: props.format, location: props.location, thinking: props.defaultThinking, tools: props.tools, sanitize: props.sanitize))
                            },
                        ]
                    )
                ),
                theme: theme
            )
        )
    }

    // parity: tui/src/ui/dialog-export-result.tsx#DialogExportResult [status=adapted hash=36d821cb1464]
    public static func DialogExportResult(
        ctx: any RenderContext,
        path: String,
        copied: Bool = false,
        dialog: DialogContext,
        theme: ResolvedTheme,
        onCopy: (@Sendable () -> Void)? = nil,
        onClose: (@Sendable () -> Void)? = nil
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let close: @Sendable () -> Void = {
            onClose?()
            dialog.clear()
        }
        return DialogLayout(
            ctx: ctx,
            id: "dialog-export-result",
            header: DialogHeader(ctx: ctx, title: "Session exported", theme: theme, onClose: close),
            body: TextRenderable(ctx: ctx, options: TextOptions(content: .string("Saved to \(path)"), fg: .rgba(surface.text.base), wrapMode: .word)),
            footer: DialogFooter(
                ctx: ctx,
                props: DialogFooterProps(
                    actions: DialogFooterActions(
                        primary: [
                            copied
                                ? DialogFooterAction(title: "copied", key: "✓", onTrigger: onCopy, color: surface.text.feedback.success.base)
                                : DialogFooterAction(title: "copy path", key: "c", onTrigger: onCopy),
                        ]
                    )
                ),
                theme: theme
            )
        )
    }

    // parity: tui/src/ui/dialog-help.tsx#DialogHelp [status=adapted hash=95c6868b59b9]
    public static func DialogHelp(
        ctx: any RenderContext,
        paletteShortcut: String = "ctrl+p",
        dialog: DialogContext,
        theme: ResolvedTheme
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let close: @Sendable () -> Void = { dialog.clear() }
        return DialogLayout(
            ctx: ctx,
            id: "dialog-help",
            header: DialogHeader(ctx: ctx, title: "Help", closeLabel: "esc/enter", theme: theme, onClose: close),
            body: TextRenderable(
                ctx: ctx,
                options: TextOptions(
                    content: .string("Press \(paletteShortcut) to see all available actions and commands in any context."),
                    fg: .rgba(surface.text.muted),
                    wrapMode: .word
                )
            ),
            footer: DialogFooter(
                ctx: ctx,
                props: DialogFooterProps(actions: DialogFooterActions(primary: [DialogFooterAction(title: "ok", key: "enter", onTrigger: close)])),
                theme: theme
            )
        )
    }

    // parity: tui/src/ui/dialog-prompt.tsx#DialogPromptAction [status=implemented hash=c75ff2e47c2b]
    public struct DialogPromptAction: Sendable {
        public let title: String
        public let command: String
        public let commandTitle: String?
        public let onTrigger: @Sendable (@Sendable (String) -> Void) -> Void

        public init(
            title: String,
            command: String,
            commandTitle: String? = nil,
            onTrigger: @escaping @Sendable (@Sendable (String) -> Void) -> Void
        ) {
            self.title = title
            self.command = command
            self.commandTitle = commandTitle
            self.onTrigger = onTrigger
        }
    }

    // parity: tui/src/ui/dialog-prompt.tsx#DialogPromptProps [status=implemented hash=7192d81b13f5]
    public struct DialogPromptProps: Sendable {
        public let title: String
        public let size: DialogSize
        public let subtitle: String?
        public let descriptionText: String?
        public let placeholder: String
        public let value: String
        public let busy: Bool
        public let busyText: String
        public let actions: [DialogPromptAction]
        public let onConfirm: (@Sendable (String) -> Void)?
        public let onCancel: (@Sendable () -> Void)?

        public init(
            title: String,
            size: DialogSize = .medium,
            subtitle: String? = nil,
            descriptionText: String? = nil,
            placeholder: String = "Enter text",
            value: String = "",
            busy: Bool = false,
            busyText: String = "Working…",
            actions: [DialogPromptAction] = [],
            onConfirm: (@Sendable (String) -> Void)? = nil,
            onCancel: (@Sendable () -> Void)? = nil
        ) {
            self.title = title
            self.size = size
            self.subtitle = subtitle
            self.descriptionText = descriptionText
            self.placeholder = placeholder
            self.value = value
            self.busy = busy
            self.busyText = busyText
            self.actions = actions
            self.onConfirm = onConfirm
            self.onCancel = onCancel
        }
    }

    /// Under new designs the dialog ends in a Submit button, with the extra actions as hints on its left; the legacy
    /// layout keeps the footer band.
    // parity: tui/src/ui/dialog-prompt.tsx#DialogPrompt [status=adapted hash=dbc31302252c]
    public static func DialogPrompt(
        ctx: any RenderContext,
        props: DialogPromptProps,
        dialog: DialogContext,
        theme: ResolvedTheme,
        newDesigns: Bool = false,
        shortcut: ((String) -> String?)? = nil
    ) -> BoxRenderable {
        dialog.setSize(props.size)
        let surface = theme.surface(.dialog)
        let body = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column, gap: .point(1)))
        if let desc = props.descriptionText, !desc.isEmpty {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(desc), fg: .rgba(surface.text.muted), wrapMode: .word)))
        }
        let inputDisplay = props.value.isEmpty ? props.placeholder : props.value
        let inputColor = props.busy
            ? surface.text.formfield.disabled
            : (props.value.isEmpty ? surface.text.muted : surface.text.formfield.base)
        body.add(TextRenderable(ctx: ctx, options: TextOptions(id: "dialog-prompt-input", content: .string(inputDisplay), fg: .rgba(inputColor))))
        if props.busy {
            body.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(props.busyText), fg: .rgba(surface.text.muted))))
        }
        let header = DialogHeader(ctx: ctx, title: props.title, description: props.subtitle, theme: theme, onClose: {
            if !props.busy { (props.onCancel ?? { dialog.clear() })() }
        })
        if newDesigns {
            let extraActions = props.actions.map { action in
                DialogFooterAction(
                    title: action.title,
                    command: action.command,
                    // The rendered prompt is a snapshot, so the action's value handle has nothing to update.
                    onTrigger: { action.onTrigger { _ in } },
                    disabled: props.busy
                )
            }
            return DialogLayout(
                ctx: ctx,
                id: "dialog-prompt",
                header: header,
                body: body,
                buttons: DialogButtons(
                    ctx: ctx,
                    buttons: [DialogButton(label: "Submit") { props.onConfirm?(props.value) }],
                    active: 0,
                    theme: theme,
                    hints: extraActions,
                    shortcut: shortcut
                )
            )
        }
        return DialogLayout(
            ctx: ctx,
            id: "dialog-prompt",
            header: header,
            body: body,
            footer: DialogFooter(
                ctx: ctx,
                props: DialogFooterProps(
                    actions: DialogFooterActions(
                        primary: [
                            DialogFooterAction(
                                title: "submit",
                                key: "enter",
                                command: "dialog.prompt.submit",
                                onTrigger: { props.onConfirm?(props.value) },
                                disabled: props.busy
                            ),
                        ]
                    )
                ),
                theme: theme
            )
        )
    }

    // parity: tui/src/ui/dialog-select.tsx#DialogSelectOption [status=implemented hash=5f0ab814105a]
    public struct DialogSelectOption<Value: Equatable & Sendable>: Sendable {
        public var title: String
        public var value: Value
        public var description: String?
        public var footer: String?
        public var searchFooter: String?
        public var footerColor: RGBA?
        public var category: String?
        public var searchText: String?
        public var disabled: Bool
        public var details: [String]?
        public var detail: String?
        public var bg: RGBA?
        public var fg: RGBA?
        public var onSelect: (@Sendable (DialogContext) -> Void)?

        public init(
            title: String,
            value: Value,
            description: String? = nil,
            footer: String? = nil,
            searchFooter: String? = nil,
            footerColor: RGBA? = nil,
            category: String? = nil,
            searchText: String? = nil,
            disabled: Bool = false,
            details: [String]? = nil,
            detail: String? = nil,
            bg: RGBA? = nil,
            fg: RGBA? = nil,
            onSelect: (@Sendable (DialogContext) -> Void)? = nil
        ) {
            self.title = title
            self.value = value
            self.description = description
            self.footer = footer
            self.searchFooter = searchFooter
            self.footerColor = footerColor
            self.category = category
            self.searchText = searchText
            self.disabled = disabled
            self.details = details
            self.detail = detail
            self.bg = bg
            self.fg = fg
            self.onSelect = onSelect
        }
    }

    // parity: tui/src/ui/dialog-select.tsx#DialogSelectProps [status=implemented hash=79dcb45a537a]
    public struct DialogSelectProps<Value: Equatable & Sendable>: Sendable {
        public var title: String
        public var description: String?
        public var placeholder: String
        public var options: [DialogSelectOption<Value>]
        public var current: Value?
        public var renderFilter: Bool
        public var flat: Bool
        public var locked: Bool
        public var filter: String
        public var selectedIndex: Int
        public var onSelect: (@Sendable (DialogSelectOption<Value>) -> Void)?
        public var onMove: (@Sendable (DialogSelectOption<Value>) -> Void)?
        public var onCancel: (@Sendable () -> Void)?
        public var footerActions: DialogFooterActions?
        /// Fill the parent's height, keeping the footer at the bottom.
        public var grow: Bool

        public init(
            title: String,
            description: String? = nil,
            placeholder: String = "Search",
            options: [DialogSelectOption<Value>],
            current: Value? = nil,
            renderFilter: Bool = true,
            flat: Bool = false,
            locked: Bool = false,
            filter: String = "",
            selectedIndex: Int = 0,
            onSelect: (@Sendable (DialogSelectOption<Value>) -> Void)? = nil,
            onMove: (@Sendable (DialogSelectOption<Value>) -> Void)? = nil,
            onCancel: (@Sendable () -> Void)? = nil,
            footerActions: DialogFooterActions? = nil,
            grow: Bool = false
        ) {
            self.grow = grow
            self.title = title
            self.description = description
            self.placeholder = placeholder
            self.options = options
            self.current = current
            self.renderFilter = renderFilter
            self.flat = flat
            self.locked = locked
            self.filter = filter
            self.selectedIndex = selectedIndex
            self.onSelect = onSelect
            self.onMove = onMove
            self.onCancel = onCancel
            self.footerActions = footerActions
        }
    }

    // parity: tui/src/ui/dialog-select.tsx#dialogSelectContentWidth [status=implemented hash=2b75364c1cdc]
    public static func dialogSelectContentWidth(_ width: Int) -> Int {
        width - DIALOG_LIST_INSET * 2 - 4
    }

    /// Imperative state handle for a `DialogSelect` list (filter, filtered items, selected item, navigation).
    // parity: tui/src/ui/dialog-select.tsx#DialogSelectRef [status=adapted hash=0b6cb2a099ab]
    public final class DialogSelectRef<Value: Equatable & Sendable>: Sendable {
        private struct State: Sendable {
            var options: [DialogSelectOption<Value>]
            var filter: String
            var selectedIndex: Int
        }

        private let state: Mutex<State>

        public init(options: [DialogSelectOption<Value>], filter: String = "", current: Value? = nil) {
            let enabled = options.filter { !$0.disabled }
            let initialIdx = current.flatMap { cur in enabled.firstIndex { $0.value == cur } } ?? 0
            self.state = Mutex(State(options: options, filter: filter, selectedIndex: initialIdx))
        }

        public var filter: String { state.withLock { $0.filter } }

        public var filtered: [DialogSelectOption<Value>] {
            state.withLock { s in Self.filterOptions(s.options, needle: s.filter) }
        }

        public var selectedIndex: Int { state.withLock { $0.selectedIndex } }

        public var selected: DialogSelectOption<Value>? {
            state.withLock { s in
                let items = Self.filterOptions(s.options, needle: s.filter)
                guard s.selectedIndex >= 0 && s.selectedIndex < items.count else { return items.first }
                return items[s.selectedIndex]
            }
        }

        public func setFilter(_ value: String) {
            state.withLock { s in
                s.filter = value
                s.selectedIndex = 0
            }
        }

        public func move(delta: Int) {
            state.withLock { s in
                let items = Self.filterOptions(s.options, needle: s.filter)
                s.selectedIndex = moveSelection(s.selectedIndex, count: items.count, delta: delta, policy: .wrap)
            }
        }

        public func moveTo(_ value: Value) {
            state.withLock { s in
                let items = Self.filterOptions(s.options, needle: s.filter)
                if let idx = items.firstIndex(where: { $0.value == value }) {
                    s.selectedIndex = idx
                }
            }
        }

        public static func filterOptions(
            _ options: [DialogSelectOption<Value>],
            needle: String
        ) -> [DialogSelectOption<Value>] {
            let enabled = options.filter { !$0.disabled }
            let query = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !query.isEmpty else { return enabled }
            return enabled.compactMap { option -> (DialogSelectOption<Value>, Int)? in
                let titleScore = fuzzyScore(query: query, target: option.title.lowercased())
                let catScore = option.category.map { fuzzyScore(query: query, target: $0.lowercased()) } ?? -1
                let searchScore = option.searchText.map { fuzzyScore(query: query, target: $0.lowercased()) } ?? -1
                let best = max(titleScore * 2, max(catScore, searchScore))
                guard best > 0 else { return nil }
                return (option, (titleScore > 0 ? titleScore * 2 : 0) + max(0, catScore) + max(0, searchScore))
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        }

        private static func fuzzyScore(query: String, target: String) -> Int {
            if target == query { return 1000 }
            if target.hasPrefix(query) { return 500 + (100 - min(99, target.count)) }
            if target.contains(query) { return 250 + (100 - min(99, target.count)) }
            // Subsequence match
            var qIdx = query.startIndex
            var score = 0
            for ch in target {
                if ch == query[qIdx] {
                    score += 10
                    qIdx = query.index(after: qIdx)
                    if qIdx == query.endIndex { return score }
                }
            }
            return -1
        }
    }

    /// Renders a searchable grouped select dialog into a `BoxRenderable`, matching `ui/dialog-select.tsx#DialogSelect`.
    ///
    /// Under new designs each row starts with a one-cell bar, `┃` on the active row in the row's own background
    /// (such as a destructive confirmation's) or the focused form-field color.
    // parity: tui/src/ui/dialog-select.tsx#DialogSelect [status=adapted hash=8e6c064e3109]
    public static func DialogSelect<Value: Equatable & Sendable>(
        ctx: any RenderContext,
        props: DialogSelectProps<Value>,
        dialog: DialogContext,
        theme: ResolvedTheme,
        newDesigns: Bool = false
    ) -> BoxRenderable {
        let surface = theme.surface(.dialog)
        let filtered = DialogSelectRef.filterOptions(props.options, needle: props.filter)
        let selectedIdx = reconcileSelection(props.selectedIndex, count: filtered.count)
        let headerBox = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column))
        headerBox.add(DialogHeader(ctx: ctx, title: props.title, description: props.description, theme: theme, onClose: props.onCancel ?? { dialog.clear() }))
        if props.renderFilter {
            let filterDisplay = props.filter.isEmpty ? props.placeholder : props.filter
            headerBox.add(
                TextRenderable(
                    ctx: ctx,
                    options: TextOptions(
                        content: .string(filterDisplay),
                        fg: .rgba(props.filter.isEmpty ? surface.text.muted : surface.text.formfield.focused)
                    )
                )
            )
        }

        let listBox = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .column))
        if filtered.isEmpty {
            let msg = props.renderFilter && !props.filter.isEmpty ? "No results found" : "No items available"
            listBox.add(TextRenderable(ctx: ctx, options: TextOptions(content: .string(msg), fg: .rgba(surface.text.muted))))
        } else {
            var lastCategory: String? = nil
            for (index, option) in filtered.enumerated() {
                let category = (props.flat && !props.filter.isEmpty) ? nil : option.category
                if let category, !category.isEmpty, category != lastCategory {
                    listBox.add(
                        TextRenderable(
                            ctx: ctx,
                            options: TextOptions(
                                content: .string(category),
                                fg: .rgba(surface.hue.accent[.s200]),
                                attributes: TextAttributes.bold
                            )
                        )
                    )
                    lastCategory = category
                }
                let isActive = !props.locked && index == selectedIdx
                let isCurrent = props.current.map { $0 == option.value } ?? false
                let marker = isCurrent ? "● " : "  "
                let fgColor = isActive
                    ? (option.fg ?? surface.text.action.primary.focused)
                    : (isCurrent ? surface.text.formfield.selected : surface.text.base)
                let bgColor = isActive ? (option.bg ?? surface.background.action.primary.focused) : nil
                let row = BoxRenderable(
                    ctx: ctx,
                    options: BoxOptions(
                        width: .percent(100),
                        flexDirection: .row,
                        justifyContent: .spaceBetween,
                        gap: .point(1),
                        onMouseUp: { _ in
                            if props.locked { return }
                            option.onSelect?(dialog)
                            props.onSelect?(option)
                        },
                        backgroundColor: bgColor.map { .rgba($0) }
                    )
                )
                let descSuffix = (option.description != nil && option.description != category) ? " \(option.description!)" : ""
                row.add(
                    TextRenderable(
                        ctx: ctx,
                        options: TextOptions(
                            content: .string("\(marker)\(option.title)\(descSuffix)"),
                            fg: .rgba(fgColor),
                            attributes: isActive ? TextAttributes.bold : TextAttributes.none,
                            wrapMode: TextWrapMode.none,
                            truncate: true
                        )
                    )
                )
                if let footer = option.footer, !footer.isEmpty {
                    row.add(
                        TextRenderable(
                            ctx: ctx,
                            options: TextOptions(
                                content: .string(footer),
                                fg: .rgba(isActive ? fgColor : (option.footerColor ?? surface.text.muted)),
                                wrapMode: TextWrapMode.none
                            )
                        )
                    )
                }
                if newDesigns {
                    let barred = BoxRenderable(ctx: ctx, options: BoxOptions(width: .percent(100), flexDirection: .row))
                    barred.add(TextRenderable(ctx: ctx, options: TextOptions(
                        content: .string(isActive ? "┃" : " "),
                        width: .point(1),
                        flexShrink: 0,
                        fg: .rgba(option.bg ?? surface.text.formfield.focused)
                    )))
                    row.flexGrow = 1
                    barred.add(row)
                    listBox.add(barred)
                } else {
                    listBox.add(row)
                }
                if let details = option.details {
                    for detail in details {
                        listBox.add(
                            TextRenderable(
                                ctx: ctx,
                                options: TextOptions(
                                    content: .string("  \(detail)"),
                                    fg: .rgba(surface.text.muted),
                                    wrapMode: TextWrapMode.none
                                )
                            )
                        )
                    }
                }
            }
        }

        // Without actions there is no footer, so the list ends one blank row above the dialog edge.
        let footerNode: Renderable? = props.footerActions.flatMap { actions in
            actions.secondary.isEmpty && actions.primary.isEmpty
                ? nil
                : DialogFooter(ctx: ctx, props: DialogFooterProps(actions: actions), theme: theme, newDesigns: newDesigns)
        }
        return DialogLayout(
            ctx: ctx,
            id: "dialog-select",
            header: headerBox,
            body: listBox,
            footer: footerNode,
            grow: props.grow
        )
    }

    /// Formats a trailing choice indicator (`‹ value ›` or `  value ↵` when active, padded otherwise).
    // parity: tui/src/ui/dialog-select.tsx#DialogSelectChoice [status=implemented hash=9580b13ed2cc]
    public static func DialogSelectChoice(
        value: String,
        active: Bool,
        open: Bool = false,
        theme: ResolvedTheme
    ) -> TextChunk {
        let surface = theme.surface(.dialog)
        let text: String
        if !active {
            text = "  \(value)  "
        } else {
            text = open ? "  \(value) ↵" : "‹ \(value) ›"
        }
        return TextChunk(text: text, fg: active ? surface.text.action.primary.focused : surface.text.muted)
    }

    // MARK: - Working Directory Actions (`src/ui/working-directory-actions.tsx`)

    public struct WorkingDirectoryActionOption: Equatable, Hashable, Sendable {
        public let title: String
        public let value: String
        public let description: String

        public init(title: String, value: String, description: String) {
            self.title = title
            self.value = value
            self.description = description
        }
    }

    public struct WorkingDirectoryActionsController: Sendable {
        public let options: @Sendable () -> [WorkingDirectoryActionOption]
        public let openMenu: @Sendable () -> [WorkingDirectoryActionOption]

        public init(
            options: @escaping @Sendable () -> [WorkingDirectoryActionOption],
            openMenu: @escaping @Sendable () -> [WorkingDirectoryActionOption]
        ) {
            self.options = options
            self.openMenu = openMenu
        }
    }

    /// Builds working-directory context menu options (`Copy path`, `Open folder`, optional `Workspaces`).
    // parity: tui/src/ui/working-directory-actions.tsx#useWorkingDirectoryActions [status=adapted hash=bc476102cbff]
    public static func useWorkingDirectoryActions(
        directory: @escaping @Sendable () -> String?,
        hasMoveHandler: Bool = false
    ) -> WorkingDirectoryActionsController {
        let buildOptions: @Sendable () -> [WorkingDirectoryActionOption] = {
            guard let dir = directory(), !dir.isEmpty else { return [] }
            var items = [
                WorkingDirectoryActionOption(title: "Copy path", value: "location.copy", description: dir),
                WorkingDirectoryActionOption(title: "Open folder", value: "location.open", description: "in system file manager"),
            ]
            if hasMoveHandler {
                items.append(WorkingDirectoryActionOption(title: "Workspaces", value: "session.move", description: "to another working directory"))
            }
            return items
        }
        return WorkingDirectoryActionsController(options: buildOptions, openMenu: buildOptions)
    }
}

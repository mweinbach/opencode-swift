import Synchronization

/// Opaque timer handle returned by `Clock.setTimeout` and `Clock.setInterval`.
// parity: core/src/lib/clock.ts#TimerHandle [status=implemented hash=75eea18a790f]
public struct TimerHandle: Equatable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// Abstract monotonic clock and timer scheduler used by renderers, theme-mode waiters,
/// animation tickers, and deterministic tests (`ManualClock`).
// parity: core/src/lib/clock.ts#Clock [status=implemented hash=7d4dfc3770bf]
public protocol Clock: AnyObject {
    /// Monotonic timestamp in milliseconds.
    func now() -> Double

    /// Schedules `fn` to run once after `delayMs` milliseconds.
    @discardableResult
    func setTimeout(_ fn: @escaping () -> Void, delayMs: Double) -> TimerHandle

    /// Cancels a previously scheduled timeout handle.
    func clearTimeout(_ handle: TimerHandle)

    /// Schedules `fn` to run repeatedly every `delayMs` milliseconds.
    @discardableResult
    func setInterval(_ fn: @escaping () -> Void, delayMs: Double) -> TimerHandle

    /// Cancels a previously scheduled interval handle.
    func clearInterval(_ handle: TimerHandle)
}

// MARK: - SystemClock

private final class SystemTimerBox: @unchecked Sendable {
    let fn: () -> Void
    var cancelled: Bool = false
    var completed: Bool = false
    var task: Task<Void, Never>?

    init(_ fn: @escaping () -> Void) {
        self.fn = fn
    }

    func cancel() {
        cancelled = true
        task?.cancel()
        task = nil
    }
}

/// Pure-Swift wall-time monotonic clock backed by Swift's `ContinuousClock` and structured `Task` timers.
/// Zero OS / Foundation / Dispatch imports.
// parity: core/src/lib/clock.ts#SystemClock [status=adapted hash=2a034ed81421]
public final class SystemClock: Clock, Sendable {
    private struct State: @unchecked Sendable {
        var nextId: UInt64 = 1
        var timers: [UInt64: SystemTimerBox] = [:]
    }

    private let startInstant: ContinuousClock.Instant
    private let state = Mutex(State())

    public init() {
        self.startInstant = ContinuousClock.now
    }

    // parity: core/src/lib/clock.ts#SystemClock.now [status=adapted hash=2ba81fdb71e8]
    public func now() -> Double {
        let elapsed = startInstant.duration(to: ContinuousClock.now)
        let (seconds, attoseconds) = elapsed.components
        return Double(seconds) * 1_000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
    }

    // parity: core/src/lib/clock.ts#SystemClock.setTimeout [status=adapted hash=bfcbe06a3399]
    @discardableResult
    public func setTimeout(_ fn: @escaping () -> Void, delayMs: Double) -> TimerHandle {
        let box = SystemTimerBox(fn)
        let duration = Self.duration(fromMs: delayMs)
        let id: UInt64 = state.withLock { s in
            if s.timers.count > 64 {
                s.timers = s.timers.filter { !$0.value.completed && !$0.value.cancelled }
            }
            let allocated = s.nextId
            s.nextId &+= 1
            if s.nextId == 0 { s.nextId = 1 }
            s.timers[allocated] = box
            return allocated
        }

        let task = Task { [weak self] in
            do {
                if duration > .zero {
                    try await Task.sleep(for: duration, clock: ContinuousClock())
                } else {
                    await Task.yield()
                }
            } catch {
                box.completed = true
                self?.removeTimer(id: id)
                return
            }
            guard !Task.isCancelled && !box.cancelled else {
                box.completed = true
                self?.removeTimer(id: id)
                return
            }
            box.completed = true
            self?.removeTimer(id: id)
            box.fn()
        }
        state.withLock { _ in
            if box.cancelled {
                task.cancel()
            } else {
                box.task = task
            }
        }
        return TimerHandle(rawValue: id)
    }

    // parity: core/src/lib/clock.ts#SystemClock.clearTimeout [status=adapted hash=81bbb1f884f9]
    public func clearTimeout(_ handle: TimerHandle) {
        let removed: SystemTimerBox? = state.withLock { s in
            let box = s.timers.removeValue(forKey: handle.rawValue)
            box?.cancel()
            return box
        }
        _ = removed
    }

    // parity: core/src/lib/clock.ts#SystemClock.setInterval [status=adapted hash=539d42e60274]
    @discardableResult
    public func setInterval(_ fn: @escaping () -> Void, delayMs: Double) -> TimerHandle {
        let box = SystemTimerBox(fn)
        let clampedMs = max(1.0, delayMs.isFinite ? delayMs : 1.0)
        let duration = Self.duration(fromMs: clampedMs)
        let id: UInt64 = state.withLock { s in
            if s.timers.count > 64 {
                s.timers = s.timers.filter { !$0.value.completed && !$0.value.cancelled }
            }
            let allocated = s.nextId
            s.nextId &+= 1
            if s.nextId == 0 { s.nextId = 1 }
            s.timers[allocated] = box
            return allocated
        }

        let task = Task { [weak self] in
            while !Task.isCancelled && !box.cancelled {
                do {
                    try await Task.sleep(for: duration, clock: ContinuousClock())
                } catch {
                    break
                }
                if Task.isCancelled || box.cancelled {
                    break
                }
                box.fn()
            }
            box.completed = true
            self?.removeTimer(id: id)
        }
        state.withLock { _ in
            if box.cancelled {
                task.cancel()
            } else {
                box.task = task
            }
        }
        return TimerHandle(rawValue: id)
    }

    // parity: core/src/lib/clock.ts#SystemClock.clearInterval [status=adapted hash=e17774da4c36]
    public func clearInterval(_ handle: TimerHandle) {
        clearTimeout(handle)
    }

    private func removeTimer(id: UInt64) {
        _ = state.withLock { s in
            s.timers.removeValue(forKey: id)
        }
    }

    private static func duration(fromMs delayMs: Double) -> Duration {
        guard delayMs.isFinite, delayMs > 0 else { return .zero }
        let clampedMs = min(delayMs, 86_400_000.0 * 365.0)
        let wholeMs = Int64(clampedMs)
        let fractionalNs = Int64((clampedMs - Double(wholeMs)) * 1_000_000.0)
        return .milliseconds(wholeMs) + .nanoseconds(fractionalNs)
    }
}

// MARK: - ManualClock

/// Deterministic virtual-time clock for headless testing, matching `core/src/testing/manual-clock.ts`.
public final class ManualClock: Clock, @unchecked Sendable {
    private struct ScheduledTimer {
        let id: UInt64
        let fireAt: Double
        let order: UInt64
        let delayMs: Double
        let `repeat`: Bool
        let fn: () -> Void
    }

    private var time: Double = 0
    private var nextId: UInt64 = 1
    private var nextOrder: UInt64 = 0
    private var timers: [UInt64: ScheduledTimer] = [:]
    private var activeTimerId: UInt64? = nil
    private var activeTimerCancelled: Bool = false

    public init(initialTime: Double = 0) {
        self.time = initialTime.isFinite ? initialTime.rounded(.down) : 0
    }

    public func now() -> Double {
        time
    }

    /// Scheduled timeouts and intervals that have not fired or been cleared.
    public var pendingTimerCount: Int {
        timers.count
    }

    public func setTime(_ newTime: Double) {
        let targetTime = newTime.isFinite ? newTime.rounded(.down) : time
        if targetTime >= time {
            advance(by: targetTime - time)
            return
        }
        time = targetTime
    }

    @discardableResult
    public func setTimeout(_ fn: @escaping () -> Void, delayMs: Double) -> TimerHandle {
        schedule(fn: fn, delayMs: delayMs, repeat: false)
    }

    public func clearTimeout(_ handle: TimerHandle) {
        if activeTimerId == handle.rawValue {
            activeTimerCancelled = true
        }
        timers.removeValue(forKey: handle.rawValue)
    }

    @discardableResult
    public func setInterval(_ fn: @escaping () -> Void, delayMs: Double) -> TimerHandle {
        schedule(fn: fn, delayMs: delayMs, repeat: true)
    }

    public func clearInterval(_ handle: TimerHandle) {
        clearTimeout(handle)
    }

    /// Advances virtual time by `delayMs` milliseconds, firing due timers in chronological
    /// (then FIFO registration) order.
    public func advance(by delayMs: Double) {
        let normalized = delayMs.isFinite ? max(0.0, delayMs.rounded(.down)) : 0.0
        let targetTime = time + normalized

        while let nextTimer = peekNextTimer(), nextTimer.fireAt <= targetTime {
            timers.removeValue(forKey: nextTimer.id)
            time = nextTimer.fireAt

            let prevActive = activeTimerId
            let prevCancelled = activeTimerCancelled
            activeTimerId = nextTimer.id
            activeTimerCancelled = false

            nextTimer.fn()

            let wasCancelled = activeTimerCancelled
            activeTimerId = prevActive
            activeTimerCancelled = prevCancelled

            if nextTimer.repeat && !wasCancelled && timers[nextTimer.id] == nil {
                let order = nextOrder
                nextOrder &+= 1
                timers[nextTimer.id] = ScheduledTimer(
                    id: nextTimer.id,
                    fireAt: time + nextTimer.delayMs,
                    order: order,
                    delayMs: nextTimer.delayMs,
                    repeat: true,
                    fn: nextTimer.fn
                )
            }
        }

        time = targetTime
    }

    /// Convenience alias for `advance(by:)`.
    public func advance(_ delayMs: Double) {
        advance(by: delayMs)
    }

    /// Advances virtual time repeatedly until all scheduled timers have fired.
    public func runAll() {
        while let nextTimer = peekNextTimer() {
            advance(by: max(0.0, nextTimer.fireAt - time))
        }
    }

    private func schedule(fn: @escaping () -> Void, delayMs: Double, repeat shouldRepeat: Bool) -> TimerHandle {
        let id = nextId
        nextId &+= 1
        let normalizedDelay = delayMs.isFinite ? max(0.0, delayMs.rounded(.down)) : 0.0
        let order = nextOrder
        nextOrder &+= 1
        timers[id] = ScheduledTimer(
            id: id,
            fireAt: time + normalizedDelay,
            order: order,
            delayMs: normalizedDelay,
            repeat: shouldRepeat,
            fn: fn
        )
        return TimerHandle(rawValue: id)
    }

    private func peekNextTimer() -> ScheduledTimer? {
        var best: ScheduledTimer? = nil
        for timer in timers.values {
            if let current = best {
                if timer.fireAt < current.fireAt || (timer.fireAt == current.fireAt && timer.order < current.order) {
                    best = timer
                }
            } else {
                best = timer
            }
        }
        return best
    }
}

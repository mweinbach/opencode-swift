/// Detected terminal color scheme mode, matching `core/src/types.ts#ThemeMode`.
// parity: core/src/types.ts#ThemeMode [status=implemented hash=bbea82d51acc]
public enum ThemeMode: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case dark
    case light
}

/// Host interface called by `RendererThemeMode` when DSR `?997` reports a theme change.
// parity: core/src/renderer-theme-mode.ts#RendererThemeModeHost [status=implemented hash=ed3e266aba5a]
public protocol RendererThemeModeHost: AnyObject {
    /// Queries terminal foreground/background colors via OSC 10/11.
    /// Returns `true` when the query ends with a DA1 sentinel; the host then calls `cancelRefresh()` at its reply.
    func queryThemeColors() -> Bool
}

/// Result returned by `RendererThemeMode.handleSequence(_:)`.
public struct ThemeModeSequenceResult: Equatable, Hashable, Sendable {
    public let handled: Bool
    public let changedMode: ThemeMode?

    public init(handled: Bool, changedMode: ThemeMode?) {
        self.handled = handled
        self.changedMode = changedMode
    }
}

// MARK: - OSC 10/11 Parsing & Brightness Classification

@inline(__always)
private func hexDigitValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: return byte - 0x30
    case 0x41...0x46: return byte - 0x41 + 10
    case 0x61...0x66: return byte - 0x61 + 10
    default: return nil
    }
}

/// Scales a 1+ hex-digit OSC RGB component to an 8-bit channel value `0...255`,
/// matching JavaScript `Math.round((parseInt(c, 16) / ((1 << (4 * c.length)) - 1)) * 255)`.
private func scaleOscThemeComponent(_ bytes: ArraySlice<UInt8>) -> UInt8 {
    let count = bytes.count
    guard count > 0 else { return 0 }

    var value: Double = 0
    for byte in bytes {
        guard let digit = hexDigitValue(byte) else { return 0 }
        value = value * 16.0 + Double(digit)
    }

    var maxValue: Double = 1.0
    for _ in 0..<count {
        maxValue *= 16.0
    }
    maxValue -= 1.0
    guard maxValue > 0 else { return 0 }

    let scaled = (value / maxValue) * 255.0
    // Match JavaScript Math.round for non-negative values: floor(x + 0.5).
    let rounded = Int((scaled + 0.5).rounded(.down))
    return UInt8(max(0, min(255, rounded)))
}

/// Computes theme mode from 8-bit sRGB channels using exact integer ITU-R BT.601 luma threshold:
/// `(r * 299 + g * 587 + b * 114) > 128000` (equivalent to `brightness > 128`).
public func inferThemeModeFromRGB(r: UInt8, g: UInt8, b: UInt8) -> ThemeMode {
    let scaledBrightness = Int(r) * 299 + Int(g) * 587 + Int(b) * 114
    return scaledBrightness > 128_000 ? .light : .dark
}

/// Infers `ThemeMode` from any color string accepted by `parseColor(_:)`.
public func inferThemeModeFromBackgroundColor(_ color: String) -> ThemeMode {
    let (r, g, b, _) = parseColor(color).toInts()
    return inferThemeModeFromRGB(r: r, g: g, b: b)
}

/// Scans `bytes` starting at `start` for an OSC 10/11 reply matching:
/// `\x1b](10|11);(?:rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+)|#([0-9a-fA-F]{6}))(?:\x07|\x1b\\)`.
private func matchOscThemeReply(
    in bytes: [UInt8],
    at start: Int
) -> (oscCode: Int, rgb: RGBTriplet, nextIndex: Int)? {
    let count = bytes.count
    // Minimum length: "\x1b]10;rgb:0/0/0\x07" = 15 or "\x1b]10;#000000\x07" = 13
    guard start + 12 < count else { return nil }
    guard bytes[start] == 0x1B, bytes[start + 1] == 0x5D else { return nil } // ESC ]
    guard bytes[start + 2] == 0x31 else { return nil } // '1'
    let codeByte = bytes[start + 3]
    guard codeByte == 0x30 || codeByte == 0x31 else { return nil } // '0' or '1'
    guard bytes[start + 4] == 0x3B else { return nil } // ';'

    let oscCode = codeByte == 0x31 ? 11 : 10
    var i = start + 5
    let rgb: RGBTriplet

    if i + 4 <= count,
       bytes[i] == 0x72, // 'r'
       bytes[i + 1] == 0x67, // 'g'
       bytes[i + 2] == 0x62, // 'b'
       bytes[i + 3] == 0x3A // ':'
    {
        i += 4
        let rStart = i
        while i < count, hexDigitValue(bytes[i]) != nil { i += 1 }
        guard i > rStart, i < count, bytes[i] == 0x2F else { return nil } // '/'
        let rSlice = bytes[rStart..<i]
        i += 1

        let gStart = i
        while i < count, hexDigitValue(bytes[i]) != nil { i += 1 }
        guard i > gStart, i < count, bytes[i] == 0x2F else { return nil } // '/'
        let gSlice = bytes[gStart..<i]
        i += 1

        let bStart = i
        while i < count, hexDigitValue(bytes[i]) != nil { i += 1 }
        guard i > bStart else { return nil }
        let bSlice = bytes[bStart..<i]

        rgb = RGBTriplet(
            scaleOscThemeComponent(rSlice),
            scaleOscThemeComponent(gSlice),
            scaleOscThemeComponent(bSlice)
        )
    } else if i + 7 <= count, bytes[i] == 0x23 { // '#'
        guard let r0 = hexDigitValue(bytes[i + 1]),
              let r1 = hexDigitValue(bytes[i + 2]),
              let g0 = hexDigitValue(bytes[i + 3]),
              let g1 = hexDigitValue(bytes[i + 4]),
              let b0 = hexDigitValue(bytes[i + 5]),
              let b1 = hexDigitValue(bytes[i + 6])
        else {
            return nil
        }
        rgb = RGBTriplet(
            (r0 << 4) | r1,
            (g0 << 4) | g1,
            (b0 << 4) | b1
        )
        i += 7
    } else {
        return nil
    }

    // Terminator: BEL (0x07) or ST (ESC \)
    if i < count && bytes[i] == 0x07 {
        return (oscCode, rgb, i + 1)
    }
    if i + 1 < count && bytes[i] == 0x1B && bytes[i + 1] == 0x5C {
        return (oscCode, rgb, i + 2)
    }
    return nil
}

// MARK: - RendererThemeMode

/// Tracks terminal dark/light theme mode from OSC 10/11 replies and DSR `?997;1n`/`?997;2n` notifications.
// parity: core/src/renderer-theme-mode.ts#RendererThemeMode [status=implemented hash=95b0cd62cce3]
public final class RendererThemeMode: @unchecked Sendable {
    public static let queryTimeoutMs: Double = 250

    private final class ThemeWaiter {
        let id: UInt64
        let resolve: (ThemeMode?) -> Void
        var timeoutHandle: TimerHandle?

        init(id: UInt64, resolve: @escaping (ThemeMode?) -> Void) {
            self.id = id
            self.resolve = resolve
        }
    }

    private unowned let host: any RendererThemeModeHost
    private let clock: any Clock

    private var _themeMode: ThemeMode? = nil
    private var refreshPending: Bool = false
    private var themeRefreshTimeoutId: TimerHandle? = nil
    private var nextWaiterId: UInt64 = 1
    private var waiters: [ThemeWaiter] = []

    public init(host: any RendererThemeModeHost, clock: any Clock) {
        self.host = host
        self.clock = clock
    }

    // parity: core/src/renderer-theme-mode.ts#RendererThemeMode.themeMode [status=implemented hash=efc3aee41ee9]
    public var themeMode: ThemeMode? {
        _themeMode
    }

    /// Callback-based waiter for deterministic synchronous resolution (especially with `ManualClock`).
    public func waitForThemeMode(
        timeoutMs: Double,
        isDestroyed: Bool,
        onResolve: @escaping (ThemeMode?) -> Void
    ) {
        if _themeMode != nil || isDestroyed || timeoutMs == 0 {
            onResolve(_themeMode)
            return
        }

        let waiterId = nextWaiterId
        nextWaiterId &+= 1
        let waiter = ThemeWaiter(id: waiterId, resolve: onResolve)

        if timeoutMs > 0 {
            waiter.timeoutHandle = clock.setTimeout({ [weak self] in
                guard let self else { return }
                self.waiters.removeAll { $0.id == waiterId }
                waiter.timeoutHandle = nil
                waiter.resolve(self._themeMode)
            }, delayMs: timeoutMs)
        }

        waiters.append(waiter)
    }

    /// Async waiter matching upstream `Promise<ThemeMode | null>`.
    // parity: core/src/renderer-theme-mode.ts#RendererThemeMode.waitForThemeMode [status=implemented hash=217cb5f0716e]
    public func waitForThemeMode(timeoutMs: Double, isDestroyed: Bool) async -> ThemeMode? {
        if _themeMode != nil || isDestroyed || timeoutMs == 0 {
            return _themeMode
        }

        return await withCheckedContinuation { continuation in
            waitForThemeMode(timeoutMs: timeoutMs, isDestroyed: isDestroyed) { mode in
                continuation.resume(returning: mode)
            }
        }
    }

    // parity: core/src/renderer-theme-mode.ts#RendererThemeMode.dispose [status=implemented hash=e8ae8a70402f]
    public func dispose() {
        cancelRefresh()
        resolveWaiters()
    }

    /// Resolves every pending waiter with the current mode (even when `nil`).
    // parity: core/src/renderer-theme-mode.ts#RendererThemeMode.resolveWaiters [status=implemented hash=22e51e9e60f0]
    public func resolveWaiters() {
        let currentWaiters = waiters
        waiters.removeAll(keepingCapacity: true)
        for waiter in currentWaiters {
            if let handle = waiter.timeoutHandle {
                clock.clearTimeout(handle)
                waiter.timeoutHandle = nil
            }
            waiter.resolve(_themeMode)
        }
    }

    // parity: core/src/renderer-theme-mode.ts#RendererThemeMode.handleSequence [status=implemented hash=ce4b12c8951b]
    public func handleSequence(_ sequence: String) -> ThemeModeSequenceResult {
        if sequence == "\u{1B}[?997;1n" || sequence == "\u{1B}[?997;2n" {
            requestThemeOscColors()
            return ThemeModeSequenceResult(handled: true, changedMode: nil)
        }

        // A reply is applied whenever it arrives: a late one still reports the terminal's current color.
        // The mode follows the background (OSC 11); foreground (OSC 10) is consumed but unused.
        let bytes = Array(sequence.utf8)
        var handled = false
        var background: RGBTriplet? = nil

        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x1B, let match = matchOscThemeReply(in: bytes, at: i) {
                handled = true
                if match.oscCode == 11 {
                    background = match.rgb
                }
                i = match.nextIndex
            } else {
                i += 1
            }
        }

        guard let background else {
            return ThemeModeSequenceResult(handled: handled, changedMode: nil)
        }

        cancelRefresh()
        let inferred = inferThemeModeFromRGB(r: background.r, g: background.g, b: background.b)
        return ThemeModeSequenceResult(handled: true, changedMode: applyThemeMode(inferred))
    }

    // parity: core/src/renderer-theme-mode.ts#RendererThemeMode.cancelRefresh [status=implemented hash=99d2537534ec]
    public func cancelRefresh() {
        refreshPending = false
        guard let handle = themeRefreshTimeoutId else { return }
        clock.clearTimeout(handle)
        themeRefreshTimeoutId = nil
    }

    private func requestThemeOscColors() {
        // Ignore repeated ?997 notifications while the current OSC refresh is still in flight.
        if refreshPending {
            return
        }

        let batched = host.queryThemeColors()
        refreshPending = true
        // Without a sentinel, a timer ends the refresh.
        if batched {
            return
        }

        themeRefreshTimeoutId = clock.setTimeout({ [weak self] in
            guard let self else { return }
            self.themeRefreshTimeoutId = nil
            self.refreshPending = false
        }, delayMs: Self.queryTimeoutMs)
    }

    private func applyThemeMode(_ mode: ThemeMode) -> ThemeMode? {
        let changed = _themeMode != mode
        _themeMode = mode

        if !changed {
            return nil
        }

        resolveWaiters()
        return mode
    }
}

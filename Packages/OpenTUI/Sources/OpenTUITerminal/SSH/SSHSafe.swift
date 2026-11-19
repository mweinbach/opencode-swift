/// Isolation guard for user callbacks, constant-time byte comparisons, and safe
/// display/error sanitization.

/// Callable error-isolation guard matching upstream `SafeInvoke`.
/// `safe(fn)` runs a callback and routes any throw to the sink; `safe.report(err)`
/// sinks an error directly. A throwing sink is contained too.
// parity: ssh/src/safe.ts#SafeInvoke [status=implemented hash=4b79ede5c4ee]
public struct SSHSafeInvoke: Sendable {
    private let sink: @Sendable (any Error) -> Void

    public init(onError: @escaping @Sendable (any Error) -> Void) {
        self.sink = onError
    }

    /// Report an error directly to the sink, without ever letting a throwing sink escape.
    public func report(_ error: any Error) {
        sink(error)
    }

    /// Run a synchronous throwing callback, routing any thrown error to the sink.
    public func callAsFunction(_ fn: () throws -> Void) {
        do {
            try fn()
        } catch {
            report(error)
        }
    }

    /// Run an asynchronous throwing callback, routing any thrown error to the sink.
    /// Always completes without throwing so callers can await safely.
    public func callAsFunction(_ fn: @Sendable () async throws -> Void) async {
        do {
            try await fn()
        } catch {
            report(error)
        }
    }
}

/// Build a `SSHSafeInvoke` over a potentially throwing `onError` sink.
// parity: ssh/src/safe.ts#createSafeInvoke [status=implemented hash=fc9c172ed919]
public func createSafeInvoke(
    onError: @escaping @Sendable (any Error) throws -> Void
) -> SSHSafeInvoke {
    SSHSafeInvoke { error in
        do {
            try onError(error)
        } catch {
            // Last frame before transport/event handlers; a throwing sink cannot escape.
        }
    }
}

/// Best-effort teardown: run `fn` and swallow any throw. Distinct from `safe`:
/// this ignores the error rather than routing it to `onError`, for cleanup paths
/// where a failure is not worth reporting.
// parity: ssh/src/safe.ts#ignoreErrors [status=implemented hash=6f139b40773d]
public func ignoreErrors(_ fn: () throws -> Void) {
    do {
        try fn()
    } catch {}
}

/// Async variant of `ignoreErrors` for best-effort async cleanup paths.
public func ignoreErrors(_ fn: () async throws -> Void) async {
    do {
        try await fn()
    } catch {}
}

/// Constant-time equality comparison for two byte slices in pure Swift.
/// Works identically on every platform including iOS and WASI without leaking
/// prefix match lengths via early exit.
public func timingSafeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard lhs.count == rhs.count else {
        // Still perform a dummy scan proportional to rhs length to reduce timing variance.
        var dummy: UInt8 = 1
        for byte in rhs {
            dummy |= byte
        }
        _ = dummy
        return false
    }
    var diff: UInt8 = 0
    for index in 0..<lhs.count {
        diff |= lhs[index] ^ rhs[index]
    }
    return diff == 0
}

/// Constant-time equality comparison for UTF-8 strings.
public func timingSafeEqual(_ lhs: String, _ rhs: String) -> Bool {
    timingSafeEqual(Array(lhs.utf8), Array(rhs.utf8))
}

/// Escape ASCII C0 (U+0000..U+001F), DEL (U+007F), and C1 (U+0080..U+009F)
/// control scalars as `\uXXXX` (lowercase 4-digit hex), preventing terminal
/// escape-sequence injection and log forging from client-controlled strings.
public func escapeControlCharacters(_ value: String) -> String {
    var result = ""
    result.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
        let code = scalar.value
        if code <= 0x1F || (code >= 0x7F && code <= 0x9F) {
            result.append("\\u")
            result.append(hex4Lower(code))
        } else {
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}

/// Format an arbitrary error safely for logs or diagnostics by escaping control
/// characters so untrusted error payloads cannot inject terminal sequences.
public func formatSafeError(_ error: any Error) -> String {
    if let sshError = error as? any SSHErrorProtocol {
        return escapeControlCharacters(sshError.message)
    }
    if let denyError = error as? DenyError {
        return escapeControlCharacters(denyError.message)
    }
    return escapeControlCharacters(String(describing: error))
}

private func hex4Lower(_ value: UInt32) -> String {
    let digits: [UInt8] = Array("0123456789abcdef".utf8)
    let bytes: [UInt8] = [
        digits[Int((value >> 12) & 0xF)],
        digits[Int((value >> 8) & 0xF)],
        digits[Int((value >> 4) & 0xF)],
        digits[Int(value & 0xF)],
    ]
    return String(decoding: bytes, as: UTF8.self)
}

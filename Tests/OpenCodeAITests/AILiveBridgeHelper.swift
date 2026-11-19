/// Streaming, timeout, and clock test helpers for `AILiveBridgeTests`
/// (deliberately does NOT import `Testing` to preserve macOS CLT cross-import compatibility).

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodeAI
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Controlled streaming `HTTPTransport` that lets tests push chunks one at a time
/// and verify that consumers receive events incrementally before subsequent chunks arrive.
final class ControlledStreamTransport: HTTPTransport, @unchecked Sendable {
    private struct State: Sendable {
        var recordedRequests: [HTTPRequest] = []
        var chunkContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation?
        var openedWaiters: [CheckedContinuation<Void, Never>] = []
        var streamOpened = false
        var wasCancelled = false
    }

    private let state = Mutex(State())
    private let responseHead: HTTPResponseHead

    init(statusCode: Int = 200, headers: [String: String] = ["content-type": "text/event-stream"]) {
        self.responseHead = HTTPResponseHead(statusCode: statusCode, headers: headers)
    }

    var recordedRequests: [HTTPRequest] {
        state.withLock { $0.recordedRequests }
    }

    var wasCancelled: Bool {
        state.withLock { $0.wasCancelled }
    }

    func waitUntilStreamOpened() async {
        await withCheckedContinuation { cont in
            let alreadyOpen = state.withLock { s -> Bool in
                if s.streamOpened { return true }
                s.openedWaiters.append(cont)
                return false
            }
            if alreadyOpen { cont.resume() }
        }
    }

    func pushChunk(_ bytes: [UInt8]) {
        let cont = state.withLock { $0.chunkContinuation }
        cont?.yield(bytes)
    }

    func pushSSE(_ text: String) {
        pushChunk(Array(text.utf8))
    }

    func finishStream(throwing error: (any Error)? = nil) {
        let cont = state.withLock { s -> AsyncThrowingStream<[UInt8], Error>.Continuation? in
            let c = s.chunkContinuation
            s.chunkContinuation = nil
            return c
        }
        if let error {
            cont?.finish(throwing: error)
        } else {
            cont?.finish()
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        state.withLock { $0.recordedRequests.append(request) }
        return HTTPResponse(head: responseHead, body: [])
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
            let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.recordedRequests.append(request)
                s.chunkContinuation = continuation
                s.streamOpened = true
                let w = s.openedWaiters
                s.openedWaiters.removeAll()
                return w
            }
            for w in waiters { w.resume() }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { s in
                    s.wasCancelled = true
                    s.chunkContinuation = nil
                }
            }
        }
        return HTTPStreamingResponse(head: responseHead, chunks: stream)
    }
}

/// Capturing `HTTPTransport` that records every request and serves scripted chunks.
final class CapturingStreamTransport: HTTPTransport, @unchecked Sendable {
    private let lock = Mutex<[HTTPRequest]>([])
    private let head: HTTPResponseHead
    private let chunks: [[UInt8]]

    init(statusCode: Int = 200, headers: [String: String] = [:], chunks: [[UInt8]]) {
        self.head = HTTPResponseHead(statusCode: statusCode, headers: headers)
        self.chunks = chunks
    }

    var recordedRequests: [HTTPRequest] {
        lock.withLock { $0 }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { $0.append(request) }
        return HTTPResponse(head: head, body: chunks.flatMap { $0 })
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        lock.withLock { $0.append(request) }
        let localChunks = chunks
        let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
            for chunk in localChunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
        return HTTPStreamingResponse(head: head, chunks: stream)
    }
}

/// Configurable delayed/stalling transport for testing `AIRequestExecutor` timeout enforcement.
final class DelayedTimeoutTransport: HTTPTransport, @unchecked Sendable {
    private let headersDelayMs: Int
    private let chunkSchedule: [(delayMs: Int, bytes: [UInt8])]
    private let stallAfterChunks: Bool
    private let cancelledFlag = Mutex(false)

    init(
        headersDelayMs: Int = 0,
        chunkSchedule: [(delayMs: Int, bytes: [UInt8])] = [],
        stallAfterChunks: Bool = false
    ) {
        self.headersDelayMs = headersDelayMs
        self.chunkSchedule = chunkSchedule
        self.stallAfterChunks = stallAfterChunks
    }

    var wasCancelled: Bool {
        cancelledFlag.withLock { $0 }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        _ = request
        if headersDelayMs > 0 {
            do {
                try await Task.sleep(for: .milliseconds(headersDelayMs))
            } catch {
                cancelledFlag.withLock { $0 = true }
                throw error
            }
        }
        return HTTPResponse(head: HTTPResponseHead(statusCode: 200), body: chunkSchedule.flatMap(\.bytes))
    }

    func stream(_ request: HTTPRequest) async throws -> HTTPStreamingResponse {
        _ = request
        if headersDelayMs > 0 {
            do {
                try await Task.sleep(for: .milliseconds(headersDelayMs))
            } catch {
                cancelledFlag.withLock { $0 = true }
                throw error
            }
        }
        let schedule = chunkSchedule
        let stall = stallAfterChunks
        let stream = AsyncThrowingStream<[UInt8], Error> { continuation in
            let producer = Task { [self] in
                do {
                    for entry in schedule {
                        if entry.delayMs > 0 {
                            try await Task.sleep(for: .milliseconds(entry.delayMs))
                        }
                        continuation.yield(entry.bytes)
                    }
                    if stall {
                        try await Task.sleep(for: .seconds(60))
                    }
                    continuation.finish()
                } catch {
                    self.cancelledFlag.withLock { $0 = true }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [self] _ in
                self.cancelledFlag.withLock { $0 = true }
                producer.cancel()
            }
        }
        return HTTPStreamingResponse(head: HTTPResponseHead(statusCode: 200), chunks: stream)
    }
}

/// Thread-safe latch for awaiting the first `textDelta` from a streaming consumer task
/// without sharing a non-`Sendable` iterator across tasks.
final class FirstDeltaLatch: Sendable {
    private struct State: Sendable {
        var value: String? = nil
        var waiters: [CheckedContinuation<String, Never>] = []
    }

    private let state = Mutex(State())

    func signal(_ text: String) {
        let waiters = state.withLock { s -> [CheckedContinuation<String, Never>] in
            guard s.value == nil else { return [] }
            s.value = text
            let w = s.waiters
            s.waiters.removeAll()
            return w
        }
        for w in waiters { w.resume(returning: text) }
    }

    func wait() async -> String {
        await withCheckedContinuation { cont in
            let existing = state.withLock { s -> String? in
                if let v = s.value { return v }
                s.waiters.append(cont)
                return nil
            }
            if let existing { cont.resume(returning: existing) }
        }
    }
}

enum LiveBridgeTimeHelper {
    static func currentEpochSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    static func utcDateStamp(epochSeconds: Int64) -> String {
        let secondsPerDay: Int64 = 86_400
        var days = epochSeconds / secondsPerDay
        let rem = epochSeconds % secondsPerDay
        if rem < 0 { days -= 1 }
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        if m <= 2 { y += 1 }
        func pad(_ v: Int64, _ width: Int) -> String {
            let s = String(v)
            return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
        }
        return "\(pad(y, 4))\(pad(m, 2))\(pad(d, 2))"
    }
}

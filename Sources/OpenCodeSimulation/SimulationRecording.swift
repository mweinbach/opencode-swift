#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Synchronization
import OpenCodePlatform
import OpenCodeUtil

/// Versioned JSONL terminal timeline and pointer sidecar recording (`packages/simulation/src/recording.ts`).
public enum SimulationRecording {
    /// Initial JSONL record describing recorded terminal geometry and payload encoding.
    // parity: simulation/src/recording.ts#Header [status=implemented hash=ff4474957bca]
    public struct Header: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let version: Int
        public let cols: Int
        public let rows: Int
        public let encoding: String

        public init(cols: Int, rows: Int) {
            self.type = "header"
            self.version = 1
            self.cols = cols
            self.rows = rows
            self.encoding = "base64"
        }

        private enum CodingKeys: String, CodingKey {
            case type, version, cols, rows, encoding
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "header" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected type 'header'")
            }
            let version = try c.decode(Int.self, forKey: .version)
            guard version == 1 else {
                throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "Expected version 1")
            }
            let encoding = try c.decode(String.self, forKey: .encoding)
            guard encoding == "base64" else {
                throw DecodingError.dataCorruptedError(forKey: .encoding, in: c, debugDescription: "Expected encoding 'base64'")
            }
            self.type = type
            self.version = version
            self.cols = try c.decode(Int.self, forKey: .cols)
            self.rows = try c.decode(Int.self, forKey: .rows)
            self.encoding = encoding
        }
    }

    /// Timestamped base64-encoded ANSI output chunk in a JSONL timeline.
    // parity: simulation/src/recording.ts#Output [status=implemented hash=8e46cb65b677]
    public struct Output: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let at_ms: Int
        public let data: String

        public init(at_ms: Int, data: String) {
            self.type = "output"
            self.at_ms = at_ms
            self.data = data
        }

        private enum CodingKeys: String, CodingKey {
            case type, at_ms, data
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "output" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected type 'output'")
            }
            self.type = type
            self.at_ms = try c.decode(Int.self, forKey: .at_ms)
            self.data = try c.decode(String.self, forKey: .data)
        }
    }

    /// Timestamped viewport resize record in a JSONL timeline.
    // parity: simulation/src/recording.ts#Resize [status=implemented hash=bcd9e4e3088f]
    public struct Resize: Equatable, Hashable, Sendable, Codable {
        public let type: String
        public let at_ms: Int
        public let cols: Int
        public let rows: Int

        public init(at_ms: Int, cols: Int, rows: Int) {
            self.type = "resize"
            self.at_ms = at_ms
            self.cols = cols
            self.rows = rows
        }

        private enum CodingKeys: String, CodingKey {
            case type, at_ms, cols, rows
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            guard type == "resize" else {
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected type 'resize'")
            }
            self.type = type
            self.at_ms = try c.decode(Int.self, forKey: .at_ms)
            self.cols = try c.decode(Int.self, forKey: .cols)
            self.rows = try c.decode(Int.self, forKey: .rows)
        }
    }

    /// Discriminated union of v1 JSONL timeline events (`header | output | resize`).
    // parity: simulation/src/recording.ts#Event [status=implemented hash=95150a8bcc44]
    public enum Event: Equatable, Hashable, Sendable, Codable {
        case header(Header)
        case output(Output)
        case resize(Resize)

        private enum TagKeys: String, CodingKey {
            case type
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: TagKeys.self)
            let kind = try c.decode(String.self, forKey: .type)
            switch kind {
            case "header":
                self = .header(try Header(from: decoder))
            case "output":
                self = .output(try Output(from: decoder))
            case "resize":
                self = .resize(try Resize(from: decoder))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown recording event type '\(kind)'")
            }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .header(let value): try value.encode(to: encoder)
            case .output(let value): try value.encode(to: encoder)
            case .resize(let value): try value.encode(to: encoder)
            }
        }
    }

    /// Pointer sidecar event written to `<timeline>.pointers.jsonl` on the same monotonic clock.
    // parity: simulation/src/recording.ts#Pointer [status=implemented hash=bd487864212d]
    public struct Pointer: Equatable, Hashable, Sendable, Codable {
        public enum Action: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
            case move
            case down
            case up
            case click
            case scroll
        }

        public let atMs: Int
        public let action: Action
        public let x: Int
        public let y: Int

        public init(atMs: Int, action: Action, x: Int, y: Int) {
            self.atMs = atMs
            self.action = action
            self.x = x
            self.y = y
        }
    }

    /// Error raised when a recording timeline or pointer sidecar stream fails.
    public struct RecordingError: Error, Equatable, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var description: String { message }
    }

    /// Parses a newline-delimited v1 timeline file into typed `Event` values.
    public static func parseTimeline(_ text: String) throws -> [Event] {
        let decoder = JSONDecoder()
        return try text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.isEmpty }
            .map { line in
                try decoder.decode(Event.self, from: Data(line.utf8))
            }
    }

    /// Parses a newline-delimited pointer sidecar file into typed `Pointer` values.
    public static func parsePointers(_ text: String) throws -> [Pointer] {
        let decoder = JSONDecoder()
        return try text
            .split(whereSeparator: \.isNewline)
            .filter { !$0.isEmpty }
            .map { line in
                try decoder.decode(Pointer.self, from: Data(line.utf8))
            }
    }

    /// Deterministic streaming JSONL recorder for terminal output, resizes, and pointer sidecar events.
    // parity: simulation/src/recording.ts#Timeline [status=implemented hash=49ee6569cffa]
    public final class Timeline: Sendable {
        public let isTTY: Bool = true
        public let path: String
        public let columns: Int
        public let rows: Int

        private struct StreamState: @unchecked Sendable {
            var outputHandle: FileHandle?
            var pointersHandle: FileHandle?
            var ended: Bool = false
            var destroyed: Bool = false
            var failure: RecordingError? = nil
            var finishOutcome: Result<String, RecordingError>? = nil
            var errorListeners: [@Sendable (RecordingError) -> Void] = []
        }

        private let state: Mutex<StreamState>
        private let startedMs: Double
        private let nowMs: @Sendable () -> Double

        private init(
            path: String,
            cols: Int,
            rows: Int,
            outputHandle: FileHandle,
            nowMs: @escaping @Sendable () -> Double
        ) {
            self.path = path
            self.columns = cols
            self.rows = rows
            self.nowMs = nowMs
            self.startedMs = nowMs()
            self.state = Mutex(StreamState(outputHandle: outputHandle))
        }

        /// Creates parent directories, opens the timeline file, and writes the v1 header line.
        // parity: simulation/src/recording.ts#Timeline.create [status=implemented hash=14f1c71836a2]
        public static func create(
            path: String,
            cols: Int,
            rows: Int,
            nowMs: (@Sendable () -> Double)? = nil
        ) async throws -> Timeline {
            let clock = nowMs ?? Self.defaultMonotonicMs
            let url = URL(fileURLWithPath: path)
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let handle = try openTruncatedForWriting(at: path)
            let timeline = Timeline(path: path, cols: cols, rows: rows, outputHandle: handle, nowMs: clock)
            let headerLine = try encodeLine(Header(cols: cols, rows: rows))
            try timeline.writeRawToOutput(headerLine)
            return timeline
        }

        /// Reports 24-bit truecolor terminal color depth for OpenTUI rendering.
        // parity: simulation/src/recording.ts#Timeline.getColorDepth [status=implemented hash=6e808a2891ef]
        public func getColorDepth() -> Int {
            24
        }

        /// Registers a callback notified if either the timeline or pointer sidecar stream fails.
        public func onError(_ listener: @escaping @Sendable (RecordingError) -> Void) {
            let existingFailure: RecordingError? = state.withLock { s in
                if let failure = s.failure {
                    return failure
                }
                s.errorListeners.append(listener)
                return nil
            }
            if let existingFailure {
                listener(existingFailure)
            }
        }

        /// Indicates whether the underlying file descriptors have been closed.
        public var isClosed: Bool {
            state.withLock { $0.outputHandle == nil && $0.pointersHandle == nil }
        }

        /// Appends a base64-encoded ANSI output chunk timestamped on the timeline's monotonic clock.
        // parity: simulation/src/recording.ts#Timeline.write [status=implemented hash=f56d29c6569f]
        @discardableResult
        public func write(
            _ bytes: [UInt8],
            callback: (@Sendable ((any Error)?) -> Void)? = nil
        ) -> Bool {
            let timestamp = elapsed()
            let shouldSkip = state.withLock { $0.ended || $0.destroyed }
            if shouldSkip {
                callback?(nil)
                return true
            }
            let event = Output(at_ms: timestamp, data: bytesToBase64(bytes))
            do {
                let line = try Self.encodeLine(event)
                try writeRawToOutput(line)
                callback?(nil)
                return true
            } catch let recErr as RecordingError {
                destroy(error: recErr)
                callback?(recErr)
                return false
            } catch {
                let recErr = RecordingError(String(describing: error))
                destroy(error: recErr)
                callback?(recErr)
                return false
            }
        }

        /// Convenience overload encoding a UTF-8 string chunk into the timeline.
        @discardableResult
        public func write(
            _ text: String,
            callback: (@Sendable ((any Error)?) -> Void)? = nil
        ) -> Bool {
            write(Array(text.utf8), callback: callback)
        }

        /// Writes a final empty output marker, flushes and closes both streams, and returns `path`.
        /// Subsequent calls return the same outcome without writing duplicate records.
        // parity: simulation/src/recording.ts#Timeline.finish [status=implemented hash=67ef1ad0710c]
        public func finish() async throws -> String {
            let outcome: Result<String, RecordingError> = state.withLock { s in
                if let cached = s.finishOutcome {
                    return cached
                }
                if let failure = s.failure {
                    Self.closeHandlesLocked(&s)
                    s.ended = true
                    s.destroyed = true
                    let result: Result<String, RecordingError> = .failure(failure)
                    s.finishOutcome = result
                    return result
                }
                s.ended = true
                let finalEvent = Output(at_ms: elapsed(), data: "")
                do {
                    let line = try Self.encodeLine(finalEvent)
                    guard let out = s.outputHandle else {
                        throw RecordingError("Timeline output stream is closed")
                    }
                    try out.write(contentsOf: Data(line.utf8))
                    try out.synchronize()
                    if let ptr = s.pointersHandle {
                        try ptr.synchronize()
                    }
                    Self.closeHandlesLocked(&s)
                    let result: Result<String, RecordingError> = .success(path)
                    s.finishOutcome = result
                    return result
                } catch let recErr as RecordingError {
                    s.failure = recErr
                    s.destroyed = true
                    Self.closeHandlesLocked(&s)
                    let result: Result<String, RecordingError> = .failure(recErr)
                    s.finishOutcome = result
                    return result
                } catch {
                    let recErr = RecordingError(String(describing: error))
                    s.failure = recErr
                    s.destroyed = true
                    Self.closeHandlesLocked(&s)
                    let result: Result<String, RecordingError> = .failure(recErr)
                    s.finishOutcome = result
                    return result
                }
            }
            return try outcome.get()
        }

        /// Appends a timestamped viewport resize event to the timeline.
        // parity: simulation/src/recording.ts#Timeline.resize [status=implemented hash=f5e3748d2e8b]
        public func resize(cols: Int, rows: Int) {
            let shouldSkip = state.withLock { $0.ended || $0.destroyed }
            if shouldSkip { return }
            let event = Resize(at_ms: elapsed(), cols: cols, rows: rows)
            do {
                let line = try Self.encodeLine(event)
                try writeRawToOutput(line)
            } catch let recErr as RecordingError {
                destroy(error: recErr)
            } catch {
                destroy(error: RecordingError(String(describing: error)))
            }
        }

        /// Appends a timestamped pointer action to the lazily opened `<base>.pointers.jsonl` sidecar.
        // parity: simulation/src/recording.ts#Timeline.pointer [status=implemented hash=2c8fbc1d4af0]
        public func pointer(action: Pointer.Action, x: Int, y: Int) {
            let shouldSkip = state.withLock { $0.ended || $0.destroyed }
            if shouldSkip { return }
            let event = Pointer(atMs: elapsed(), action: action, x: x, y: y)
            let sidecarPath = Self.pointerSidecarPath(for: path)
            do {
                let line = try Self.encodeLine(event)
                let errorToReport: RecordingError? = state.withLock { s in
                    if s.ended || s.destroyed { return nil }
                    if s.pointersHandle == nil {
                        do {
                            s.pointersHandle = try Self.openTruncatedForWriting(at: sidecarPath)
                        } catch let err as RecordingError {
                            return err
                        } catch {
                            return RecordingError(String(describing: error))
                        }
                    }
                    guard let handle = s.pointersHandle else {
                        return RecordingError("Pointer sidecar stream is closed")
                    }
                    do {
                        try handle.write(contentsOf: Data(line.utf8))
                        return nil
                    } catch {
                        return RecordingError(String(describing: error))
                    }
                }
                if let errorToReport {
                    destroy(error: errorToReport)
                }
            } catch {
                destroy(error: RecordingError(String(describing: error)))
            }
        }

        /// Aborts both streams with an explicit error (matching Node stream failure propagation).
        public func fail(_ message: String) {
            destroy(error: RecordingError(message))
        }

        /// Computes the pointer sidecar path for a given timeline path (`<path without .jsonl>.pointers.jsonl`).
        public static func pointerSidecarPath(for timelinePath: String) -> String {
            if timelinePath.hasSuffix(".jsonl") {
                return String(timelinePath.dropLast(6)) + ".pointers.jsonl"
            }
            return timelinePath + ".pointers.jsonl"
        }

        // MARK: - Internal Helpers

        private func elapsed() -> Int {
            max(0, Int((nowMs() - startedMs).rounded()))
        }

        private func writeRawToOutput(_ line: String) throws {
            let errorToThrow: RecordingError? = state.withLock { s in
                guard !s.destroyed, let handle = s.outputHandle else {
                    return s.failure ?? RecordingError("Timeline output stream is closed")
                }
                do {
                    try handle.write(contentsOf: Data(line.utf8))
                    return nil
                } catch {
                    return RecordingError(String(describing: error))
                }
            }
            if let errorToThrow {
                throw errorToThrow
            }
        }

        private func destroy(error: RecordingError) {
            let listeners: [@Sendable (RecordingError) -> Void] = state.withLock { s in
                if s.failure == nil {
                    s.failure = error
                }
                s.destroyed = true
                Self.closeHandlesLocked(&s)
                let copy = s.errorListeners
                s.errorListeners.removeAll()
                return copy
            }
            for listener in listeners {
                listener(error)
            }
        }

        private static func closeHandlesLocked(_ s: inout StreamState) {
            if let out = s.outputHandle {
                try? out.close()
                s.outputHandle = nil
            }
            if let ptr = s.pointersHandle {
                try? ptr.close()
                s.pointersHandle = nil
            }
        }

        private static func openTruncatedForWriting(at path: String) throws -> FileHandle {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                throw RecordingError("EISDIR: illegal operation on a directory, open '\(path)'")
            }
            if !FileManager.default.createFile(atPath: path, contents: Data()) {
                throw RecordingError("Failed to create recording file at '\(path)'")
            }
            let url = URL(fileURLWithPath: path)
            return try FileHandle(forWritingTo: url)
        }

        private static func encodeLine<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return String(decoding: data, as: UTF8.self) + "\n"
        }

        private static let clockOrigin = ContinuousClock.now

        private static let defaultMonotonicMs: @Sendable () -> Double = {
            let duration = clockOrigin.duration(to: .now)
            let seconds = Double(duration.components.seconds)
            let attoseconds = Double(duration.components.attoseconds)
            return seconds * 1_000.0 + attoseconds / 1_000_000_000_000_000.0
        }
    }
}

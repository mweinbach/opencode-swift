import OpenCodeSchema
import Synchronization

// MARK: - Claude Accounts (`core/src/plugin/provider/claude-agent/claude/accounts.ts`)

extension CorePlugin.ClaudeAgent {
    /// Rotates a Claude Code chat across the configured account folders (`configDir`) when one refuses with a limit,
    /// and keeps each chat on the account that holds its transcript and prompt cache.
    public enum Accounts {
        // parity: core/src/plugin/provider/claude-agent/claude/accounts.ts#Storage [status=implemented hash=01ce4e86e530]
        public struct Storage: Sendable {
            public let get: @Sendable (String) async throws -> JSONValue?
            public let set: @Sendable (String, String) async throws -> Void

            public init(
                get: @escaping @Sendable (String) async throws -> JSONValue?,
                set: @escaping @Sendable (String, String) async throws -> Void
            ) {
                self.get = get
                self.set = set
            }
        }

        // parity: core/src/plugin/provider/claude-agent/claude/accounts.ts#Interface [status=adapted hash=1b67216da789]
        public struct Interface: Sendable {
            public let run: @Sendable (Sessions.RunRequest, [String]) async throws -> Void

            public func run(_ request: Sessions.RunRequest, configDirs: [String]) async throws {
                try await run(request, configDirs)
            }
        }

        static let LAST = "last-account"

        // parity: core/src/plugin/provider/claude-agent/claude/accounts.ts#key [status=implemented hash=ac650962fcb6]
        public static func key(_ sessionID: String) -> String { "accounts/\(sessionID)" }

        // parity: core/src/plugin/provider/claude-agent/claude/accounts.ts#make [status=implemented hash=f91b986219f2]
        public static func make(
            sessions: @escaping @Sendable (Sessions.RunRequest) async throws -> Void,
            storage: Storage
        ) -> Interface {
            @Sendable func read(_ key: String) async -> String? {
                guard case .string(let value) = try? await storage.get(key) else { return nil }
                return value
            }

            return Interface { request, configDirs in
                let connection = request.connection
                // An API key or token logs in the same way whatever the folder, so those requests never rotate.
                if configDirs.count < 2
                    || !(connection?["ANTHROPIC_API_KEY"] ?? "").isEmpty
                    || !(connection?["ANTHROPIC_AUTH_TOKEN"] ?? "").isEmpty
                {
                    return try await sessions(request)
                }
                let own = await request.sessionID.asyncFlatMap { await read(key($0)) }
                let last = await read(LAST)
                // Side calls and new forks start on their parent chat's account, which has its transcript and prompt cache.
                let parent = own == nil ? await request.sourceID.asyncFlatMap { await read(key($0)) } : nil
                let from = own ?? parent ?? last
                let start = from.flatMap { configDirs.firstIndex(of: $0) } ?? 0
                let dirs = Array(configDirs[start...] + configDirs[..<start])
                for (index, dir) in dirs.enumerated() {
                    let attempt = Attempt(emit: request.emit)
                    var env = connection ?? [:]
                    env["CLAUDE_CONFIG_DIR"] = dir
                    try await sessions(request.with(connection: env, emit: { attempt.emit($0) }))
                    guard let error = attempt.error() else {
                        // A side call never moves its chat, because the side call's model may have hit a limit of its own.
                        if let sessionID = request.sessionID, dir != own { try await storage.set(key(sessionID), dir) }
                        if dir != last { try await storage.set(LAST, dir) }
                        attempt.flush()
                        return
                    }
                    // Only a limit is worth another account. A retry after Claude has shown output would repeat that output.
                    if !error.limited || attempt.shown() || index == dirs.count - 1 {
                        attempt.flush()
                        return
                    }
                }
            }
        }

        /// Holds an attempt's messages until Claude shows output, so a refused attempt can be retried on another
        /// account without the user seeing its error.
        final class Attempt: Sendable {
            private struct State {
                var held: [ErrorMapper.SDKMessage]? = []
                var error: ErrorMapper.Failure?
            }

            private let emitDownstream: @Sendable (ErrorMapper.SDKMessage) -> Void
            private let failure = ErrorMapper.make()
            private let state = Mutex(State())

            init(emit: @escaping @Sendable (ErrorMapper.SDKMessage) -> Void) {
                self.emitDownstream = emit
            }

            func emit(_ message: ErrorMapper.SDKMessage) {
                let failed = failure(message)
                let release: [ErrorMapper.SDKMessage] = state.withLock { s in
                    if let failed { s.error = failed }
                    guard var held = s.held else { return [message] }
                    let visible: Bool = {
                        switch message {
                        case .streamEvent: return true
                        case .assistant(_, let error): return error == nil
                        default: return false
                        }
                    }()
                    if !visible {
                        held.append(message)
                        s.held = held
                        return []
                    }
                    s.held = nil
                    return held + [message]
                }
                for item in release { emitDownstream(item) }
            }

            func flush() {
                let release = state.withLock { s -> [ErrorMapper.SDKMessage] in
                    let held = s.held ?? []
                    s.held = nil
                    return held
                }
                for item in release { emitDownstream(item) }
            }

            func shown() -> Bool { state.withLock { $0.held == nil } }

            func error() -> ErrorMapper.Failure? { state.withLock { $0.error } }
        }
    }
}

extension Optional where Wrapped: Sendable {
    fileprivate func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}

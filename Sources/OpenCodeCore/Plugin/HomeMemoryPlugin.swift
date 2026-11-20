#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Home Folder Memory (`core/src/plugin/home-memory.ts`)

extension CorePlugin {
    /// Gives sessions in the home folder a persistent `memory/`, `docs/` and `scripts/` workspace the agent can use
    /// freely, tidied by a daily maintenance session that reads the day's home-folder conversations. Behind the
    /// `home_memory` flag.
    public enum HomeMemoryPlugin {
        static let DAY: Double = 24 * 60 * 60 * 1000
        static let MESSAGE_LIMIT = 4_000
        static let SESSION_LIMIT = 40_000
        static let TOTAL_LIMIT = 200_000

        struct State: Equatable, Sendable, Codable {
            let session: String
            let last: Double
        }

        /// The reference description the agent reads for the workspace at `directory`.
        public static func description(_ directory: String) -> String {
            [
                "Your own long-term workspace for helping this user across sessions. It persists between conversations and nothing in it is loaded automatically, so look here before asking the user something they may have told you before, and before redoing work.",
                "- \(PluginContract.joinPath(directory, "memory")): what you know about the user and want to remember: preferences, people, accounts, decisions, corrections they gave you.",
                "- \(PluginContract.joinPath(directory, "docs")): documents you write or manage for the user.",
                "- \(PluginContract.joinPath(directory, "scripts")): reusable scripts you build for recurring tasks.",
                "Read, write, reorganize and delete anything in it whenever it helps. Keep files small and well named so grep finds them. Don't use it for throwaway scratch work.",
            ].joined(separator: "\n")
        }

        /// The daily maintenance prompt over the home-folder conversations since the last run.
        public static func maintenance(_ directory: String, transcripts: String) -> String {
            """
            Daily memory maintenance. Nobody is watching; don't ask questions.

            Your workspace is \(directory), with memory/, docs/ and scripts/ folders. Below are the conversations the user had in their home folder since the last run (user and assistant text only, long messages cut).

            1. Pick up anything worth remembering that isn't saved yet: preferences, facts about the user and the people and things in their life, decisions, corrections, recurring tasks. Skip one-off details and anything already saved.
            2. Update what changed and delete what's stale or wrong.
            3. Reorganize: merge duplicates, split files that grew too big, rename unclear files, keep the layout easy to grep.

            Work only inside \(directory). Finish with a short summary of what you added, changed and removed.

            <conversations>
            \(transcripts)
            </conversations>
            """
        }

        static func cut(_ text: String) -> String {
            // JavaScript `slice` counts UTF-16 code units.
            let units = Array(text.utf16)
            guard units.count > MESSAGE_LIMIT else { return text }
            return String(decoding: units.prefix(MESSAGE_LIMIT), as: UTF16.self) + " [cut]"
        }

        /// One conversation's user and assistant text, or "" when the user said nothing in it.
        public static func transcript(title: String, messages: [SessionMessageSchema.Info]) -> String {
            let lines: [String] = messages.flatMap { message -> [String] in
                switch message {
                case .user(let user):
                    return ["user: \(cut(user.text))"]
                case .assistant(let assistant):
                    let text = assistant.content.compactMap { part -> String? in
                        if case .text(let t) = part { return t.text }
                        return nil
                    }.joined()
                    return text.isEmpty ? [] : ["assistant: \(cut(text))"]
                default:
                    return []
                }
            }
            if !lines.contains(where: { $0.hasPrefix("user: ") }) { return "" }
            let body = lines.joined(separator: "\n")
            let units = Array(body.utf16)
            let kept = units.count > SESSION_LIMIT ? String(decoding: units.suffix(SESSION_LIMIT), as: UTF16.self) : body
            return "<conversation title=\"\(title.replacing("\"", with: "'"))\">\n\(kept)\n</conversation>"
        }

        /// Joins transcripts until the total would pass `TOTAL_LIMIT`, skipping empty ones.
        static func joinTranscripts(_ sections: [String]) -> String {
            sections
                .filter { !$0.isEmpty }
                .reduce("") { all, section in
                    all.utf16.count + section.utf16.count > TOTAL_LIMIT ? all : "\(all)\(section)\n\n"
                }
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public struct Dependencies: Sendable {
            public let globalPaths: Global.Interface
            public let fileSystem: any OpenCodeFileSystem
            /// A session's messages, as upstream `ctx.session.context`.
            public let messages: @Sendable (SessionID) async throws -> [SessionMessageSchema.Info]
            public let nowMs: @Sendable () -> Double

            public init(
                globalPaths: Global.Interface = Global.make(),
                fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
                messages: @escaping @Sendable (SessionID) async throws -> [SessionMessageSchema.Info] = { _ in [] },
                nowMs: @escaping @Sendable () -> Double = { Double(Flock.currentEpochMs()) }
            ) {
                self.globalPaths = globalPaths
                self.fileSystem = fileSystem
                self.messages = messages
                self.nowMs = nowMs
            }
        }

        /// One maintenance pass: at most daily, it reuses (or creates) the maintenance session and queues a prompt over
        /// the home-folder conversations updated since the last pass.
        static func tick(ctx: PluginEffect.Context, directory: String, deps: Dependencies) async throws {
            let key = "state/\(ctx.location.project.id.rawValue)"
            let now = deps.nowMs()
            let state: State? = try await ctx.storage.get(key).flatMap { raw in
                guard let data = try? JSONEncoder().encode(raw) else { return nil }
                return try? JSONDecoder().decode(State.self, from: data)
            }
            if let state, now - state.last < DAY { return }
            var session: SessionID?
            if let previous = state?.session, let id = SessionID(rawValue: previous) {
                session = try? await ctx.session.get(id).id
            }
            if session == nil {
                session = try await ctx.session.create("Memory maintenance", nil, nil).id
            }
            guard let session else { return }
            let since = state?.last ?? now - DAY
            let recent = try await ctx.session.list()
                .filter {
                    $0.parentID == nil
                        && $0.id != session
                        && $0.location.directory == ctx.location.directory.rawValue
                        && Double($0.time.updated) > since
                }
                .sorted { $0.time.updated > $1.time.updated }
                .prefix(100)
            var sections: [String] = []
            for item in recent {
                let messages = (try? await deps.messages(item.id)) ?? []
                sections.append(transcript(title: item.title ?? item.id.rawValue, messages: messages))
            }
            let transcripts = joinTranscripts(sections)
            try await ctx.storage.set(key, .object(["session": .string(session.rawValue), "last": .double(now)]))
            if transcripts.isEmpty { return }
            try await ctx.session.prompt(
                session,
                PromptInputSchema.Prompt(text: maintenance(directory, transcripts: transcripts)),
                .queue
            )
        }

        public static func make(_ deps: Dependencies = Dependencies()) -> PluginEffect.Plugin {
            PluginEffect.define(
                PluginEffect.Plugin(id: "opencode.home-memory") { ctx in
                    guard await Host.flagEnabled("home_memory") else { return }
                    let home = deps.globalPaths.home
                    guard CoreConfigDiscovery.resolvePath(base: "/", relative: ctx.location.directory.rawValue)
                        == CoreConfigDiscovery.resolvePath(base: "/", relative: home)
                    else { return }
                    let directory = PluginContract.joinPath(
                        PluginContract.joinPath(deps.globalPaths.data, "memory"),
                        ctx.location.project.id.rawValue
                    )
                    for name in ["memory", "docs", "scripts"] {
                        // A folder that can't be created is logged upstream and left for the agent.
                        try? await deps.fileSystem.makeDirectory(at: PluginContract.joinPath(directory, name), recursive: true)
                    }

                    _ = await ctx.reference.transform { editor in
                        editor.add(
                            "memory",
                            .local(ReferenceSchema.LocalSource(
                                path: SchemaPrimitive.AbsolutePath(rawValue: directory),
                                description: description(directory)
                            ))
                        )
                    }

                    // Locations unload when idle, so this runs at most daily and only while the home folder is in use.
                    let ticker = Task {
                        while !Task.isCancelled {
                            try? await tick(ctx: ctx, directory: directory, deps: deps)
                            try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
                        }
                    }
                    ctx.addFinalizer { ticker.cancel() }
                }
            )
        }

        // parity: core/src/plugin/home-memory.ts#Plugin [status=adapted hash=608913dd42a8]
        public static let Plugin = make()
    }
}

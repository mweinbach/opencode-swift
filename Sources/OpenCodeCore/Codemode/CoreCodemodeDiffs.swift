import OpenCodeSchema
import OpenCodeUtil
import Synchronization

extension CoreCodemode {
    // MARK: - Code Mode File Diffs Collector (`core/src/codemode/diffs.ts`)

    public enum Diffs {
        /// The most patch text an execute call keeps on its part; changes past it keep only their counts.
        // parity: core/src/codemode/diffs.ts#MAX_PATCH_BYTES [status=implemented hash=7b35db6f5ff8]
        public static let MAX_PATCH_BYTES: Int = 200_000

        /// The most changes an execute call lists.
        // parity: core/src/codemode/diffs.ts#MAX_FILES [status=implemented hash=d7cf912dbe29]
        public static let MAX_FILES: Int = 50

        // parity: core/src/codemode/diffs.ts#Status [status=implemented hash=3e0469b30837]
        public typealias Status = FileDiffSchema.Status

        /// One change a program made to a file, in the order it made them. Counts are absent where they aren't known.
        // parity: core/src/codemode/diffs.ts#File [status=implemented hash=c11d405bff25]
        public struct File: Equatable, Hashable, Sendable, Codable {
            public let file: String
            public let status: Status
            public let additions: Int?
            public let deletions: Int?
            public let patch: String?

            public init(
                file: String,
                status: Status,
                additions: Int? = nil,
                deletions: Int? = nil,
                patch: String? = nil
            ) {
                self.file = file
                self.status = status
                self.additions = additions
                self.deletions = deletions
                self.patch = patch
            }

            public func toJSONValue() -> JSONValue {
                var dict: [String: JSONValue] = [
                    "file": .string(file),
                    "status": .string(status.rawValue),
                ]
                if let additions { dict["additions"] = .int(Int64(additions)) }
                if let deletions { dict["deletions"] = .int(Int64(deletions)) }
                if let patch { dict["patch"] = .string(patch) }
                return .object(dict)
            }
        }

        /// Collects file changes as they arrive within `MAX_FILES` and `MAX_PATCH_BYTES` budgets.
        // parity: core/src/codemode/diffs.ts#Collector [status=implemented hash=138e95134790]
        public final class Collector: Sendable {
            private struct State: Sendable {
                var entries: [File] = []
                var budget: Int = MAX_PATCH_BYTES
            }

            private let state = Mutex(State())
            /// Reports the changes recorded so far, as the program runs.
            public let changed: @Sendable () async -> Void

            public init(changed: @escaping @Sendable () async -> Void = {}) {
                self.changed = changed
            }

            public func record(_ change: File) {
                state.withLock { s in
                    if s.entries.count >= MAX_FILES { return }
                    guard let patch = change.patch else {
                        s.entries.append(File(
                            file: change.file,
                            status: change.status,
                            additions: change.additions,
                            deletions: change.deletions,
                            patch: nil
                        ))
                        return
                    }
                    let size = patch.utf8.count
                    if size > s.budget {
                        s.entries.append(File(
                            file: change.file,
                            status: change.status,
                            additions: change.additions,
                            deletions: change.deletions,
                            patch: nil
                        ))
                        return
                    }
                    s.budget -= size
                    s.entries.append(change)
                }
            }

            public func files() -> [File] {
                state.withLock { $0.entries }
            }
        }

        /// The changes a Code Mode program made to files. Nothing here reads a file: each change brings its own diff.
        // parity: core/src/codemode/diffs.ts#Service [status=adapted hash=dad734f8841d]
        public final class Service: Sendable {
            public static let serviceKey = "@opencode/CodeModeDiffs"
            @TaskLocal public static var current: Collector? = nil

            public let collector: Collector

            public init(collector: Collector) {
                self.collector = collector
            }
        }

        /// Creates a bounded diff collector; `changed` runs when a change is recorded so progress updates stay live.
        // parity: core/src/codemode/diffs.ts#make [status=implemented hash=b4981dc2a625]
        public static func make(changed: @escaping @Sendable () async -> Void = {}) -> Collector {
            Collector(changed: changed)
        }

        /// Records a change when the run has a collector.
        // parity: core/src/codemode/diffs.ts#record [status=implemented hash=e2ab920fe60b]
        public static func record(_ change: File) async {
            guard let collector = Service.current else { return }
            collector.record(change)
            await collector.changed()
        }

        /// A change written in full: the diff the write path already built for its permission request, or what is known.
        /// An overwrite that changed nothing is no change.
        // parity: core/src/codemode/diffs.ts#written [status=implemented hash=46021fb0d3cd]
        public static func written(
            _ target: CoreFilesystem.FileAccess.Target,
            status: Status,
            preview: FileDiffSchema.Info?
        ) async {
            await written(resource: target.resource, status: status, preview: preview)
        }

        /// Convenience overload for callers that already hold the location-relative or external resource path.
        public static func written(
            resource: String,
            status: Status,
            preview: FileDiffSchema.Info?
        ) async {
            if status == .modified, let preview,
               preview.additions.rawValue == 0, preview.deletions.rawValue == 0
            {
                return
            }
            if let preview {
                await record(File(
                    file: resource,
                    status: status,
                    additions: preview.additions.rawValue,
                    deletions: preview.deletions.rawValue,
                    patch: preview.patch
                ))
            } else {
                await record(File(file: resource, status: status))
            }
        }

        /// Text added to the end of a file: its lines are what it adds, counted without reading the file.
        // parity: core/src/codemode/diffs.ts#appended [status=implemented hash=149a212c8f6d]
        public static func appended(
            _ target: CoreFilesystem.FileAccess.Target,
            status: Status,
            text: String?
        ) async {
            await appended(resource: target.resource, status: status, text: text)
        }

        /// Convenience overload for callers that already hold the location-relative or external resource path.
        public static func appended(
            resource: String,
            status: Status,
            text: String?
        ) async {
            if let text {
                await record(File(file: resource, status: status, additions: countLines(text), deletions: 0))
            } else {
                await record(File(file: resource, status: status))
            }
        }

        private static func countLines(_ text: String) -> Int {
            if text.isEmpty { return 0 }
            let lfCount = text.utf8.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
            return (lfCount + 1) - (text.utf8.last == 0x0A ? 1 : 0)
        }

        private static func decodeIntField(_ value: JSONValue) -> Int? {
            switch value {
            case .int(let n): return Int(n)
            case .double(let d) where d.isFinite && d.rounded() == d: return Int(d)
            default: return nil
            }
        }

        private static func decodeChangedFile(_ value: JSONValue) -> File? {
            guard case .object(let obj) = value,
                  case .string(let file) = obj["file"]
            else {
                return nil
            }
            let status: Status
            if let rawStatus = obj["status"] {
                guard case .string(let s) = rawStatus, let parsed = Status(rawValue: s) else {
                    return nil
                }
                status = parsed
            } else {
                status = .modified
            }
            var additions: Int? = nil
            if let rawAdd = obj["additions"] {
                guard let parsed = decodeIntField(rawAdd) else { return nil }
                additions = parsed
            }
            var deletions: Int? = nil
            if let rawDel = obj["deletions"] {
                guard let parsed = decodeIntField(rawDel) else { return nil }
                deletions = parsed
            }
            var patch: String? = nil
            if let rawPatch = obj["patch"] {
                guard case .string(let s) = rawPatch else { return nil }
                patch = s
            }
            return File(file: file, status: status, additions: additions, deletions: deletions, patch: patch)
        }

        private static func matchWriteOutput(_ output: String) -> (verb: String, file: String)? {
            let verb: String
            let rest: Substring
            if output.hasPrefix("Created file successfully: ") {
                verb = "Created"
                rest = output.dropFirst("Created file successfully: ".count)
            } else if output.hasPrefix("Wrote file successfully: ") {
                verb = "Wrote"
                rest = output.dropFirst("Wrote file successfully: ".count)
            } else {
                return nil
            }
            guard !rest.isEmpty else { return nil }
            for scalar in rest.unicodeScalars {
                if scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" {
                    return nil
                }
            }
            return (verb, String(rest))
        }

        /// The changes an inner call made, from its own result. Edit and patch return each file's diff in `metadata.files`.
        /// Write returns none, so its change comes from what it was asked to write: a created file's lines are its content;
        /// an overwrite's counts aren't known without reading the file.
        // parity: core/src/codemode/diffs.ts#changes [status=implemented hash=3004a916b9b3]
        public static func changes(
            tool: String,
            input: JSONValue,
            result: ToolSchema.Result<JSONValue>
        ) -> [File] {
            if tool == "edit" || tool == "patch" {
                guard case .array(let items) = result.metadata?["files"] else { return [] }
                return items.compactMap(decodeChangedFile)
            }
            if tool != "write" { return [] }
            guard case .object(let args) = input,
                  case .string = args["path"],
                  case .string(let content) = args["content"],
                  case .string(let out) = result.output,
                  let match = matchWriteOutput(out)
            else {
                return []
            }
            if match.verb == "Wrote" {
                return [File(file: match.file, status: .modified)]
            }
            let diff = CoreTool.fileDiff(file: match.file, before: "", after: content, status: .added)
            return [File(
                file: match.file,
                status: .added,
                additions: diff.additions.rawValue,
                deletions: 0,
                patch: diff.patch
            )]
        }

        /// Runs an inner tool call and records the changes its result reports.
        // parity: core/src/codemode/diffs.ts#around [status=implemented hash=f603272c63dd]
        public static func around<E: Error>(
            _ collector: Collector,
            tool: String,
            input: JSONValue,
            body: () async throws(E) -> ToolSchema.Result<JSONValue>
        ) async throws(E) -> ToolSchema.Result<JSONValue> {
            let result = try await body()
            let found = changes(tool: tool, input: input, result: result)
            for change in found {
                collector.record(change)
            }
            if !found.isEmpty {
                await collector.changed()
            }
            return result
        }
    }
}

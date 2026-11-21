import OpenCodeSchema

// MARK: - Model Tool Policy (`core/src/tool/model-policy.ts`)

extension CoreTool {
    /// Chooses which tools a session's model sees and which tools that allow Code Mode stay direct.
    /// `CoreTool.Service.snapshot` applies the result through `SnapshotOptions.tools`.
    public enum ModelPolicy {
        private static let fullCodeModeHidden = ["glob", "grep", "webfetch"]

        // parity: core/src/tool/model-policy.ts#ModelTools [status=implemented hash=e126f45ff1ad]
        public struct ModelTools: Equatable, Sendable {
            public let hidden: Set<String>
            public let direct: Set<String>

            public init(hidden: Set<String>, direct: Set<String>) {
                self.hidden = hidden
                self.direct = direct
            }

            /// The placement as the `Policy` that `CoreTool.Service.snapshot` reads.
            public var policy: Policy { Policy(hidden: hidden, direct: direct) }
        }

        // parity: core/src/tool/model-policy.ts#modelTools [status=implemented hash=1f6087769c17]
        public static func modelTools(
            model: ModelSchema.Info?,
            websearch: Bool,
            fullCodeMode: Bool
        ) -> ModelTools {
            var hidden = Set<String>()
            if !websearch { hidden.insert("websearch") }
            // Code Mode programs search and fetch through shell and their `fetch` global, so these tools only add noise.
            if fullCodeMode { for name in fullCodeModeHidden { hidden.insert(name) } }

            // GPT-5+ edits with patch; every other model edits with edit and write.
            if let model {
                for name in usesPatch(model) ? ["edit", "write"] : ["patch"] {
                    hidden.insert(name)
                }
            }

            return ModelTools(hidden: hidden, direct: [])
        }

        private static func usesPatch(_ model: ModelSchema.Info) -> Bool {
            let id = model.id.rawValue.lowercased()
            let modelID = model.modelID.rawValue.lowercased()
            return (id.contains("gpt-") || modelID.contains("gpt-"))
                && !id.contains("oss")
                && !modelID.contains("oss")
                && !id.contains("gpt-4")
                && !modelID.contains("gpt-4")
        }
    }
}

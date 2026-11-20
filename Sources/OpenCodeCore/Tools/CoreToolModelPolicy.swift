import OpenCodeSchema

// MARK: - Model Tool Policy (`core/src/tool/model-policy.ts`)

extension CoreTool {
    /// Chooses which tools a session's model sees and which tools that allow Code Mode stay direct.
    /// `CoreTool.Service.snapshot` applies the result through `SnapshotOptions.tools`.
    public enum ModelPolicy {
        private static let codeModeBuiltIns = ["read", "write", "edit", "patch", "shell", "websearch"]
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

        // parity: core/src/tool/model-policy.ts#modelTools [status=implemented hash=354b8379af49]
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
                if editMode(model) == .patch {
                    hidden.insert("edit")
                    hidden.insert("write")
                } else {
                    hidden.insert("patch")
                }
            }

            // With full_codemode, strong models (GPT and Claude) use the built-ins from inside Code Mode;
            // every other model, or an unresolved one, keeps them as direct tools.
            var direct = Set<String>()
            if fullCodeMode && !strongModel(model) {
                for name in codeModeBuiltIns where !hidden.contains(name) {
                    direct.insert(name)
                }
            }
            return ModelTools(hidden: hidden, direct: direct)
        }

        private enum EditMode: Equatable {
            case patch
            case edit
        }

        private static func editMode(_ model: ModelSchema.Info) -> EditMode? {
            gptMode(id: model.id.rawValue.lowercased(), modelID: model.modelID.rawValue.lowercased())
        }

        private static func strongModel(_ model: ModelSchema.Info?) -> Bool {
            guard let model else { return false }
            let id = model.id.rawValue.lowercased()
            let modelID = model.modelID.rawValue.lowercased()
            return gptMode(id: id, modelID: modelID) != nil || isAnthropic(model, id: id, modelID: modelID)
        }

        private static func gptMode(id: String, modelID: String) -> EditMode? {
            if !id.contains("gpt") && !modelID.contains("gpt") { return nil }
            let usePatch = (id.contains("gpt-") || modelID.contains("gpt-"))
                && !id.contains("oss")
                && !modelID.contains("oss")
                && !id.contains("gpt-4")
                && !modelID.contains("gpt-4")
            return usePatch ? .patch : .edit
        }

        private static func isAnthropic(_ model: ModelSchema.Info, id: String, modelID: String) -> Bool {
            model.providerID.rawValue == "anthropic"
                || model.providerID.rawValue == "claude-agent"
                || model.canonical?.rawValue == "anthropic"
                || model.canonical?.rawValue == "claude-agent"
                || id.contains("claude")
                || modelID.contains("claude")
                || (model.family?.rawValue.lowercased().contains("claude") ?? false)
        }
    }
}

import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

// MARK: - Session Search Config Plugin (`core/src/config/plugin/session-search.ts`)

extension CoreConfigPlugin {
    public enum SessionSearch {
        public static let id = "opencode.config.session-search"

        /// Starts the session search build once this location has the `sqlite_fts` flag on. The build itself runs once
        /// per process: later starts do nothing, and turning the flag off does not stop it.
        /// Returns whether the flag was on, and so whether the build was started.
        @discardableResult
        public static func apply(flags: any CoreFlag.Interface, build: any SessionSearchBuild.Interface) async -> Bool {
            guard let key = ConfigFlagSchema.Key(rawValue: "sqlite_fts"), await flags.enabled(key) else { return false }
            await build.start()
            return true
        }

        /// The plugin bound to a location's flags and the process-wide build: `apply` runs on load and again on every
        /// `config.updated`, which is when the host re-applies config modules.
        public static func plugin(flags: any CoreFlag.Interface, build: any SessionSearchBuild.Interface) -> ModuleDescriptor {
            ModuleDescriptor(id: id) { _ in
                await apply(flags: flags, build: build)
            }
        }

        // parity: core/src/config/plugin/session-search.ts#Plugin [status=adapted hash=d8ff958f0e89]
        public static let Plugin = ModuleDescriptor(id: id)
    }
}

/// Resolved global base directories matching `packages/util/src/global-roots.ts` (XDG on POSIX/macOS/Linux,
/// XDG-overridable or `%LOCALAPPDATA%` on Windows, tmp-rooted fallback on sandboxed/WASI runtimes).
public struct GlobalRoots: Equatable, Hashable, Sendable, Codable {
    public let data: String
    public let cache: String
    public let config: String
    public let state: String
    public let tmp: String

    public init(data: String, cache: String, config: String, state: String, tmp: String) {
        self.data = data
        self.cache = cache
        self.config = config
        self.state = state
        self.tmp = tmp
    }
}

public enum GlobalPaths {
    // parity: util/src/global-roots.ts#roots [status=implemented hash=e489d5d92086]
    public static func roots(
        app: String = "opencode",
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        os: PlatformOS = Platform.current
    ) -> GlobalRoots {
        let sep = String(os.pathSeparator)
        func join(_ parts: String...) -> String {
            var cleaned: [String] = []
            for (idx, part) in parts.enumerated() {
                if part.isEmpty { continue }
                var s = part
                if idx > 0 {
                    while s.hasPrefix("/") || s.hasPrefix("\\") { s.removeFirst() }
                }
                while s.count > 1 && (s.hasSuffix("/") || s.hasSuffix("\\")) { s.removeLast() }
                cleaned.append(s)
            }
            return cleaned.joined(separator: sep)
        }

        let tmpRoot = join(environment.temporaryDirectory, app)
        let home = environment.homeDirectory

        func envOrNil(_ key: String) -> String? {
            guard let val = environment.variable(key), !val.isEmpty else { return nil }
            return val
        }

        if os == .wasi || home == nil {
            let base = envOrNil("XDG_DATA_HOME") ?? tmpRoot
            return GlobalRoots(
                data: join(envOrNil("XDG_DATA_HOME") ?? base, app),
                cache: join(envOrNil("XDG_CACHE_HOME") ?? base, app),
                config: join(envOrNil("XDG_CONFIG_HOME") ?? base, app),
                state: join(envOrNil("XDG_STATE_HOME") ?? base, app),
                tmp: tmpRoot
            )
        }

        let h = home!
        let dataBase = envOrNil("XDG_DATA_HOME") ?? join(h, ".local", "share")
        let cacheBase = envOrNil("XDG_CACHE_HOME") ?? join(h, ".cache")
        let configBase = envOrNil("XDG_CONFIG_HOME") ?? join(h, ".config")
        let stateBase = envOrNil("XDG_STATE_HOME") ?? join(h, ".local", "state")

        return GlobalRoots(
            data: join(dataBase, app),
            cache: join(cacheBase, app),
            config: join(configBase, app),
            state: join(stateBase, app),
            tmp: tmpRoot
        )
    }
}

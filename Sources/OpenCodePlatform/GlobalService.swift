import OpenCodeUtil

public extension GlobalPaths {
    /// Workerd / sandboxed single-tmp-directory root layout matching `util/src/global-roots.workerd.ts`.
    // parity: util/src/global-roots.workerd.ts#roots [status=implemented hash=d11ac8453ac8]
    static func workerdRoots(
        app: String = "opencode",
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> GlobalRoots {
        let baseTmp = environment.temporaryDirectory
        let trimmed = baseTmp.count > 1 && baseTmp.hasSuffix("/") ? String(baseTmp.dropLast()) : baseTmp
        let root = "\(trimmed)/\(app)"
        return GlobalRoots(
            data: "\(root)/data",
            cache: "\(root)/cache",
            config: "\(root)/config",
            state: "\(root)/state",
            tmp: "\(root)/tmp"
        )
    }
}

/// Global directory paths and injectable service matching `packages/util/src/global.ts`.
public enum Global {
    // parity: util/src/global.ts#Interface [status=implemented hash=aa26d25defae]
    public struct Interface: Equatable, Hashable, Sendable, Codable {
        public let home: String
        public let data: String
        public let cache: String
        public let config: String
        public let state: String
        public let tmp: String
        public let bin: String
        public let log: String
        public let repos: String

        public init(
            home: String,
            data: String,
            cache: String,
            config: String,
            state: String,
            tmp: String,
            bin: String,
            log: String,
            repos: String
        ) {
            self.home = home
            self.data = data
            self.cache = cache
            self.config = config
            self.state = state
            self.tmp = tmp
            self.bin = bin
            self.log = log
            self.repos = repos
        }
    }

    public struct Overrides: Equatable, Hashable, Sendable {
        public var home: String?
        public var data: String?
        public var cache: String?
        public var config: String?
        public var state: String?
        public var tmp: String?
        public var bin: String?
        public var log: String?
        public var repos: String?

        public init(
            home: String? = nil,
            data: String? = nil,
            cache: String? = nil,
            config: String? = nil,
            state: String? = nil,
            tmp: String? = nil,
            bin: String? = nil,
            log: String? = nil,
            repos: String? = nil
        ) {
            self.home = home
            self.data = data
            self.cache = cache
            self.config = config
            self.state = state
            self.tmp = tmp
            self.bin = bin
            self.log = log
            self.repos = repos
        }
    }

    // parity: util/src/global.ts#Path [status=implemented hash=888309e59712]
    public static var Path: Interface {
        make()
    }

    // parity: util/src/global.ts#Service [status=implemented hash=c202787be55d]
    public struct Service: Sendable {
        public static let serviceKey = "@opencode/Global"
        public let paths: Interface

        public init(_ paths: Interface) {
            self.paths = paths
        }
    }

    // parity: util/src/global.ts#make [status=implemented hash=0bec3fcad96c]
    public static func make(
        _ overrides: Overrides = Overrides(),
        environment: any EnvironmentProviding = SystemEnvironment.shared,
        os: PlatformOS = Platform.current
    ) -> Interface {
        let r = GlobalPaths.roots(app: "opencode", environment: environment, os: os)
        let sep = String(os.pathSeparator)
        let home = overrides.home ?? environment.homeDirectory ?? r.tmp
        let data = overrides.data ?? r.data
        let cache = overrides.cache ?? r.cache
        let config = overrides.config ?? r.config
        let state = overrides.state ?? r.state
        let tmp = overrides.tmp ?? r.tmp
        return Interface(
            home: home,
            data: data,
            cache: cache,
            config: config,
            state: state,
            tmp: tmp,
            bin: overrides.bin ?? "\(cache)\(sep)bin",
            log: overrides.log ?? "\(data)\(sep)log",
            repos: overrides.repos ?? "\(data)\(sep)repos"
        )
    }

    // parity: util/src/global.ts#layerWith [status=implemented hash=697ce716e661]
    public static func layerWith(
        _ overrides: Overrides = Overrides(),
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> LayerNode.ExecutableLayer {
        LayerNode.ExecutableLayer { _, _ in
            let paths = make(overrides, environment: environment)
            for dir in [paths.data, paths.config, paths.state, paths.log, paths.bin, paths.repos, paths.tmp] {
                try? await fileSystem.makeDirectory(at: dir, recursive: true)
            }
            let canonicalTmp = (try? await fileSystem.realPath(at: paths.tmp)) ?? paths.tmp
            let resolved = Interface(
                home: paths.home,
                data: paths.data,
                cache: paths.cache,
                config: paths.config,
                state: paths.state,
                tmp: overrides.tmp ?? canonicalTmp,
                bin: paths.bin,
                log: paths.log,
                repos: paths.repos
            )
            return LayerNode.Output([Service.serviceKey: Service(resolved)])
        }
    }

    // parity: util/src/global.ts#node [status=implemented hash=0690353164c9]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, scope in
            let configOverride = SystemEnvironment.shared.variable("OPENCODE_CONFIG_DIR")
            return try await layerWith(Overrides(config: configOverride)).build(deps, scope)
        },
        []
    )
}

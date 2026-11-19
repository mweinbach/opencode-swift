import OpenCodeUtil

/// Cross-platform `.npmrc` configuration loader matching `packages/util/src/npm-config.ts`.
public enum NpmConfig {
    /// Loads flat `.npmrc` configuration keys for `dir` plus `NPM_CONFIG_*` environment variables.
    // parity: util/src/npm-config.ts#load [status=implemented hash=6bb1a540cdc1]
    public static func load(
        dir: String,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) async -> [String: String] {
        var config: [String: String] = [:]
        var candidates: [String] = []
        if let home = environment.homeDirectory {
            candidates.append("\(home)/.npmrc")
        }
        candidates.append("\(dir)/.npmrc")

        for path in candidates {
            guard let bytes = try? await fileSystem.readFile(at: path) else { continue }
            let text = String(decoding: bytes, as: UTF8.self)
            for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    config[key] = val
                }
            }
        }
        if let envRegistry = environment.variable("NPM_CONFIG_REGISTRY") ?? environment.variable("npm_config_registry"),
           !envRegistry.isEmpty {
            config["registry"] = envRegistry
        }
        return config
    }

    /// Resolves the effective npm registry URL (trailing slash stripped), defaulting to `https://registry.npmjs.org`.
    // parity: util/src/npm-config.ts#registry [status=implemented hash=0e9f0c2b125f]
    public static func registry(
        dir: String,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) async -> String {
        let config = await load(dir: dir, fileSystem: fileSystem, environment: environment)
        let raw = config["registry"] ?? "https://registry.npmjs.org"
        return raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }
}

/// Managed npm cache service matching `packages/util/src/npm.ts`.
public enum NpmPlatform {
    // parity: util/src/npm.ts#Interface [status=implemented hash=492660a6754d]
    public protocol Interface: Sendable {
        func add(_ pkg: String) async throws -> NpmSpec.Package
        func resolve(_ pkg: String) async -> NpmSpec.Package
        func check(_ pkg: String) async throws -> Bool
        func update(_ pkg: String) async throws -> NpmSpec.Package
        func which(_ pkg: String, bin: String?) async -> String?
    }

    // parity: util/src/npm.ts#Service [status=implemented hash=fe977ad18650]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Npm"
        private let cacheRoot: String
        private let fsUtil: FSUtil.Service
        private let flock: EffectFlock.Service

        public init(
            cacheRoot: String,
            fsUtil: FSUtil.Service = FSUtil.Service(),
            flock: EffectFlock.Service? = nil
        ) {
            self.cacheRoot = cacheRoot
            self.fsUtil = fsUtil
            self.flock = flock ?? EffectFlock.Service(lockRoot: "\(cacheRoot)/locks", fileSystem: fsUtil.fileSystem)
        }

        private func packageDir(for pkg: String) -> String {
            "\(cacheRoot)/npm/\(NpmSpec.cacheKey(pkg))"
        }

        private func generations(in dir: String) async -> [String] {
            guard let entries = try? await fsUtil.fileSystem.readDirectory(at: dir) else { return [] }
            return entries
                .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
                .sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        }

        public func resolve(_ pkg: String) async -> NpmSpec.Package {
            let dir = packageDir(for: pkg)
            let gens = await generations(in: dir)
            let active = gens.last.map { "\(dir)/\($0)" } ?? dir
            let name: String
            switch NpmSpec.parse(pkg) {
            case .registry(let parsedName, _, _): name = parsedName
            case .git(let optName, _, _): name = optName ?? pkg
            case nil: name = pkg
            }
            return NpmSpec.Package(directory: active, name: name)
        }

        public func add(_ pkg: String) async throws -> NpmSpec.Package {
            guard NpmSpec.isInstallablePackage(pkg) else {
                throw NpmSpec.InstallFailedError(add: [pkg], dir: packageDir(for: pkg), causeMessage: "Invalid package spec")
            }
            let dir = packageDir(for: pkg)
            return try await flock.withLock(key: "npm:\(pkg)", dir: nil) {
                try await self.fsUtil.ensureDir(dir)
                return await self.resolve(pkg)
            }
        }

        public func check(_ pkg: String) async throws -> Bool {
            let resolved = await resolve(pkg)
            return await fsUtil.isDir(resolved.directory)
        }

        public func update(_ pkg: String) async throws -> NpmSpec.Package {
            try await add(pkg)
        }

        public func which(_ pkg: String, bin: String? = nil) async -> String? {
            let resolved = await resolve(pkg)
            let binName = bin ?? resolved.name.split(separator: "/").last.map(String.init) ?? resolved.name
            let candidate = "\(resolved.directory)/node_modules/.bin/\(binName)"
            return (await fsUtil.existsSafe(candidate)) ? candidate : nil
        }
    }

    // parity: util/src/npm.ts#node [status=implemented hash=677b73ca514c]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths ?? Global.make()
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self) ?? FSUtil.Service()
            let flock = deps.get(EffectFlock.Service.serviceKey, as: EffectFlock.Service.self)
            return LayerNode.Output([Service.serviceKey: Service(cacheRoot: global.cache, fsUtil: fsUtil, flock: flock)])
        },
        [FSUtil.node, Global.node, LayerNodePlatform.filesystem, EffectFlock.node]
    )
}

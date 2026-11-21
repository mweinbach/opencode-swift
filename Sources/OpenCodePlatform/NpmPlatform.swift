import OpenCodeUtil

/// Cross-platform `.npmrc` configuration loader matching `packages/util/src/npm-config.ts`.
public enum NpmConfig {
    /// Loads flat `.npmrc` configuration keys for `dir` plus `NPM_CONFIG_*` environment variables.
    // parity: util/src/npm-config.ts#load [status=implemented hash=aa081a54307a]
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
    // parity: util/src/npm-config.ts#registry [status=implemented hash=5ecd2814387e]
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
    /// Injectable package installer hook invoked to populate a versioned generation directory.
    public typealias Installer = @Sendable (_ pkg: String, _ generationDir: String, _ update: Bool) async throws -> Void

    /// Default subprocess-backed package installer running `bun add` (falling back to `npm install --prefix`)
    /// via `ProcessSpawner` on desktop OSes (macOS, Linux, Windows).
    public static func defaultProcessInstaller(
        spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared,
        fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared,
        environment: any EnvironmentProviding = SystemEnvironment.shared
    ) -> Installer {
        { pkg, generationDir, update in
            #if os(macOS) || os(Linux) || os(Windows)
            // Seed a minimal private package.json inside the generation directory so bun/npm
            // never walks up to modify an ancestor workspace manifest.
            let manifestPath = "\(generationDir)/package.json"
            if !(await fileSystem.exists(at: manifestPath)) {
                try? await fileSystem.writeFile(
                    Array("{\"private\":true}\n".utf8),
                    to: manifestPath,
                    createDirectories: true
                )
            }

            let configuredRegistry = await NpmConfig.registry(
                dir: generationDir,
                fileSystem: fileSystem,
                environment: environment
            )
            let customRegistry: String? = configuredRegistry == "https://registry.npmjs.org" ? nil : configuredRegistry

            // 1. Try `bun add` first when Bun is available on PATH.
            var bunArgs = ["add", "--no-progress", "--cwd", generationDir]
            if let customRegistry {
                bunArgs.append(contentsOf: ["--registry", customRegistry])
            }
            bunArgs.append(pkg)

            var bunFailureMessage: String? = nil
            var bunFailureStderr: String? = nil
            var shouldFallbackToNpm = false
            do {
                let bunOutput = try await spawner.run(
                    ProcessSpec(
                        executable: "bun",
                        arguments: bunArgs,
                        workingDirectory: generationDir
                    )
                )
                if bunOutput.exitCode == 0 {
                    return
                }
                if bunOutput.exitCode == 127 {
                    shouldFallbackToNpm = true
                } else {
                    bunFailureMessage = "bun add exited with status \(bunOutput.exitCode)"
                    bunFailureStderr = String(decoding: bunOutput.stderr, as: UTF8.self)
                    shouldFallbackToNpm = true
                }
            } catch {
                shouldFallbackToNpm = true
                bunFailureMessage = String(describing: error)
            }

            // 2. Fallback to `npm install --prefix <generationDir>`.
            if shouldFallbackToNpm {
                var npmArgs = [
                    "install",
                    "--prefix", generationDir,
                    "--no-audit",
                    "--no-fund",
                    "--ignore-scripts",
                ]
                if update {
                    npmArgs.append("--prefer-online")
                }
                if let customRegistry {
                    npmArgs.append(contentsOf: ["--registry", customRegistry])
                }
                npmArgs.append(pkg)

                do {
                    let npmOutput = try await spawner.run(
                        ProcessSpec(
                            executable: "npm",
                            arguments: npmArgs,
                            workingDirectory: generationDir
                        )
                    )
                    if npmOutput.exitCode == 0 {
                        return
                    }
                    let npmStderr = String(decoding: npmOutput.stderr, as: UTF8.self)
                    throw NpmSpec.InstallFailedError(
                        add: [pkg],
                        dir: generationDir,
                        causeMessage: "npm install exited with status \(npmOutput.exitCode)",
                        causeStderr: npmStderr.isEmpty ? bunFailureStderr : npmStderr
                    )
                } catch let err as NpmSpec.InstallFailedError {
                    throw err
                } catch {
                    throw NpmSpec.InstallFailedError(
                        add: [pkg],
                        dir: generationDir,
                        causeMessage: bunFailureMessage ?? String(describing: error),
                        causeStderr: bunFailureStderr
                    )
                }
            }
            #else
            _ = (spawner, fileSystem, environment, update)
            throw NpmSpec.InstallFailedError(
                add: [pkg],
                dir: generationDir,
                causeMessage: "Package installation is unsupported on \(Platform.current.os.rawValue)"
            )
            #endif
        }
    }

    /// Pure static half of upstream `Npm.follows`: determines whether `pkg` names a mutable target to auto-update
    /// (`@latest`, a semver range, or a git `semver:` range). For a git spec with a named `#ref` that is neither a
    /// commit hash nor a `semver:` range, returns `gitRef` so the caller can check whether the remote lists it as a
    /// branch.
    public static func staticFollows(_ pkg: String) -> (follows: Bool, gitRef: String?) {
        guard let parsed = NpmSpec.parse(pkg) else { return (false, nil) }
        switch parsed {
        case .registry(let name, let spec, let mutable):
            // npm parses a bare name as the range `*`; only a written `@latest` or range follows.
            guard pkg != name else { return (false, nil) }
            if spec == "latest" { return (true, nil) }
            guard mutable else { return (false, nil) }
            return (isSemverRangeSpec(spec), nil)
        case .git(_, _, let mutable):
            guard mutable else { return (false, nil) }
            guard let hashIndex = pkg.firstIndex(of: "#") else { return (false, nil) }
            let rawRef = String(pkg[pkg.index(after: hashIndex)...])
            guard !rawRef.isEmpty else { return (false, nil) }
            if rawRef.hasPrefix("semver:") {
                return (true, nil)
            }
            return (false, rawRef)
        }
    }

    private static func isSemverRangeSpec(_ spec: String) -> Bool {
        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "*" || trimmed.lowercased() == "x" { return true }
        let rangePrefixes = ["^", "~", ">", "<", "="]
        if rangePrefixes.contains(where: { trimmed.hasPrefix($0) }) { return true }
        if trimmed.contains("||") || trimmed.contains(" - ") || trimmed.contains(" ") { return true }
        // Wildcard or partial numeric range like `1`, `1.2`, `1.x`, `1.2.X`, `1.*`
        let stripped = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = stripped.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty && parts.count <= 3 else { return false }
        let isPartRange: (Substring) -> Bool = { part in
            part == "*" || part == "x" || part == "X" || (!part.isEmpty && part.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 })
        }
        guard parts.allSatisfy(isPartRange) else { return false }
        return parts.count < 3 || parts.contains(where: { $0 == "*" || $0 == "x" || $0 == "X" })
    }

    // parity: util/src/npm.ts#Interface [status=implemented hash=9d3c71267af9]
    public protocol Interface: Sendable {
        func add(_ pkg: String) async throws -> NpmSpec.Package
        func resolve(_ pkg: String) async -> NpmSpec.Package
        func check(_ pkg: String) async throws -> Bool
        func update(_ pkg: String) async throws -> NpmSpec.Package
        /// Whether newer versions should install on their own because the package names what to follow: `name@latest`,
        /// a version range, a Git `semver:` range, or a Git ref the remote lists as a branch. A bare name or
        /// repository, other dist-tags, Git tags and commits stay on what's installed.
        func follows(_ pkg: String) async throws -> Bool
        /// Stop using the newest installed version when it is `version`, so the previous one is current again. Its
        /// files stay until they expire, for anything still running it. False when it isn't the newest or there is
        /// no previous one.
        func reject(_ pkg: String, version: String) async throws -> Bool
        func which(_ pkg: String, bin: String?) async -> String?
    }

    // parity: util/src/npm.ts#Service [status=implemented hash=fe977ad18650]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/Npm"
        private let cacheRoot: String
        private let fsUtil: FSUtil.Service
        private let flock: EffectFlock.Service
        private let installer: Installer?
        private let gitRefIsBranch: (@Sendable (_ pkg: String, _ ref: String) async throws -> Bool)?
        private let nowMs: @Sendable () -> Int64

        public init(
            cacheRoot: String,
            fsUtil: FSUtil.Service = FSUtil.Service(),
            flock: EffectFlock.Service? = nil,
            installer: Installer? = nil,
            gitRefIsBranch: (@Sendable (_ pkg: String, _ ref: String) async throws -> Bool)? = nil,
            nowMs: @escaping @Sendable () -> Int64 = { Flock.currentEpochMs() }
        ) {
            self.cacheRoot = cacheRoot
            self.fsUtil = fsUtil
            self.flock = flock ?? EffectFlock.Service(lockRoot: "\(cacheRoot)/locks", fileSystem: fsUtil.fileSystem)
            if let installer {
                self.installer = installer
            } else if fsUtil.fileSystem is LocalFileSystem {
                self.installer = NpmPlatform.defaultProcessInstaller(fileSystem: fsUtil.fileSystem)
            } else {
                // Preserve pure in-memory testability when using virtual filesystems without an injected installer.
                self.installer = nil
            }
            self.gitRefIsBranch = gitRefIsBranch
            self.nowMs = nowMs
        }

        public func follows(_ pkg: String) async throws -> Bool {
            let staticResult = NpmPlatform.staticFollows(pkg)
            guard let ref = staticResult.gitRef else {
                return staticResult.follows
            }
            if let gitRefIsBranch {
                return try await gitRefIsBranch(pkg, ref)
            }
            return false
        }

        private func packageDir(for pkg: String) -> String {
            "\(cacheRoot)/npm/\(NpmSpec.cacheKey(pkg))"
        }

        private func parsedPackageName(for pkg: String) -> String {
            switch NpmSpec.parse(pkg) {
            case .registry(let parsedName, _, _): return parsedName
            case .git(let optName, _, _): return optName ?? pkg
            case nil: return pkg
            }
        }

        private func generations(in dir: String) async -> [String] {
            guard let entries = try? await fsUtil.fileSystem.readDirectory(at: dir) else { return [] }
            let rejected = Set(entries.filter { $0.hasSuffix(".rejected") })
            return entries
                .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) && !rejected.contains("\($0).rejected") }
                .sorted { (Int64($0) ?? 0) < (Int64($1) ?? 0) }
        }

        private func readInstalledVersion(in activeDir: String, packageName: String) async -> String? {
            let pkgJsonPath = "\(activeDir)/node_modules/\(packageName)/package.json"
            guard let parsed = try? await fsUtil.readJson(pkgJsonPath),
                  case .object(let pairs) = parsed else {
                return nil
            }
            for (key, value) in pairs where key == "version" {
                if case .string(let ver) = value, !ver.isEmpty {
                    return ver
                }
            }
            return nil
        }

        public func resolve(_ pkg: String) async -> NpmSpec.Package {
            let dir = packageDir(for: pkg)
            let gens = await generations(in: dir)
            let active = gens.last.map { "\(dir)/\($0)" } ?? dir
            let name = parsedPackageName(for: pkg)
            let version = await readInstalledVersion(in: active, packageName: name)
            return NpmSpec.Package(directory: active, name: name, version: version)
        }

        private func install(_ pkg: String, update: Bool) async throws -> NpmSpec.Package {
            guard NpmSpec.isInstallablePackage(pkg) else {
                throw NpmSpec.InstallFailedError(add: [pkg], dir: packageDir(for: pkg), causeMessage: "Invalid package spec")
            }
            let dir = packageDir(for: pkg)
            let pkgName = parsedPackageName(for: pkg)
            return try await flock.withLock(key: "npm:\(pkg)", dir: nil) {
                try await self.fsUtil.ensureDir(dir)
                if let installer = self.installer {
                    let existingGens = await self.generations(in: dir)
                    if !update, let latest = existingGens.last {
                        let activeDir = "\(dir)/\(latest)"
                        let hasPackageDir = await self.fsUtil.isDir("\(activeDir)/node_modules/\(pkgName)")
                        let hasNodeModules = hasPackageDir ? true : await self.fsUtil.isDir("\(activeDir)/node_modules")
                        if hasNodeModules {
                            return await self.resolve(pkg)
                        }
                    }

                    let newest = existingGens.last.flatMap(Int64.init) ?? 0
                    let nextGeneration = max(self.nowMs(), newest + 1)
                    let generationDir = "\(dir)/\(nextGeneration)"
                    try await self.fsUtil.ensureDir(generationDir)
                    do {
                        try await installer(pkg, generationDir, update)
                    } catch {
                        try? await self.fsUtil.fileSystem.remove(at: generationDir)
                        if let installErr = error as? NpmSpec.InstallFailedError {
                            throw installErr
                        }
                        throw NpmSpec.InstallFailedError(
                            add: [pkg],
                            dir: generationDir,
                            causeMessage: String(describing: error)
                        )
                    }
                }
                return await self.resolve(pkg)
            }
        }

        public func add(_ pkg: String) async throws -> NpmSpec.Package {
            try await install(pkg, update: false)
        }

        public func check(_ pkg: String) async throws -> Bool {
            let resolved = await resolve(pkg)
            return await fsUtil.isDir(resolved.directory)
        }

        public func update(_ pkg: String) async throws -> NpmSpec.Package {
            try await install(pkg, update: true)
        }

        public func reject(_ pkg: String, version: String) async throws -> Bool {
            let dir = packageDir(for: pkg)
            let pkgName = parsedPackageName(for: pkg)
            return try await flock.withLock(key: "npm:\(pkg)", dir: nil) {
                let completed = await self.generations(in: dir)
                guard completed.count >= 2, let newest = completed.last else { return false }
                let root = "\(dir)/\(newest)"
                guard await self.readInstalledVersion(in: root, packageName: pkgName) == version else { return false }
                do {
                    try await self.fsUtil.writeWithDirs("\(dir)/\(newest).rejected", content: [])
                } catch {
                    throw NpmSpec.InstallFailedError(add: [pkg], dir: dir, causeMessage: String(describing: error))
                }
                return true
            }
        }

        public func which(_ pkg: String, bin: String? = nil) async -> String? {
            let resolved = await resolve(pkg)
            let binName = bin ?? resolved.name.split(separator: "/").last.map(String.init) ?? resolved.name
            let candidate = "\(resolved.directory)/node_modules/.bin/\(binName)"
            return (await fsUtil.existsSafe(candidate)) ? candidate : nil
        }
    }

    // parity: util/src/npm.ts#node [status=implemented hash=abb06ef83989]
    public static let node: LayerNode.Provider = AppNode.makeGlobalNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            let global = deps.get(Global.Service.serviceKey, as: Global.Service.self)?.paths ?? Global.make()
            let fsUtil = deps.get(FSUtil.Service.serviceKey, as: FSUtil.Service.self) ?? FSUtil.Service()
            let flock = deps.get(EffectFlock.Service.serviceKey, as: EffectFlock.Service.self)
            let spawner = deps.get(CrossSpawnSpawner.spawnerKey, as: (any ProcessSpawner).self)
            let installer: Installer? = spawner.map {
                NpmPlatform.defaultProcessInstaller(spawner: $0, fileSystem: fsUtil.fileSystem)
            }
            return LayerNode.Output([
                Service.serviceKey: Service(
                    cacheRoot: global.cache,
                    fsUtil: fsUtil,
                    flock: flock,
                    installer: installer
                ),
            ])
        },
        [FSUtil.node, Global.node, LayerNodePlatform.filesystem, EffectFlock.node]
    )
}

public extension NpmPlatform.Interface {
    func follows(_ pkg: String) async throws -> Bool {
        NpmPlatform.staticFollows(pkg).follows
    }
}

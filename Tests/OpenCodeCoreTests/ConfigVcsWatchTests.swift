import Synchronization
import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

/// Core-tier unit tests matching upstream `config/watch.test.ts`, `config/config.test.ts`,
/// `config/reload.test.ts`, `filesystem/location-watcher.ts`, `filesystem/location-watcher-policy.test.ts`,
/// `vcs.test.ts`, `vcs-hg.test.ts`, and `location-activity.ts`.
@Suite("Core ConfigWatch, LocationWatcher, and VCS watch parity")
struct ConfigVcsWatchTests {

    private func makeGlobal(root: String) -> Global.Interface {
        Global.make(Global.Overrides(
            home: "\(root)/home",
            data: "\(root)/data",
            cache: "\(root)/cache",
            config: "\(root)/global",
            state: "\(root)/state",
            tmp: "\(root)/tmp",
            bin: "\(root)/bin",
            log: "\(root)/log",
            repos: "\(root)/repos"
        ))
    }

    private func makeBus() throws -> CoreBus.Service {
        let db = try SQLiteDatabaseFactory.open(path: ":memory:")
        return CoreBus.Service(db: db)
    }

    private func abs(_ path: String) -> SchemaPrimitive.AbsolutePath {
        SchemaPrimitive.AbsolutePath(rawValue: path)
    }

    private func waitUntil(
        timeoutMs: Int = 2_500,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Flock.currentEpochMs() + Int64(timeoutMs)
        while Flock.currentEpochMs() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    // MARK: - ConfigWatch.plan & ConfigWatch.inputs

    @Test("CoreConfigWatch.plan groups missing candidates, keeps parent watches when roots appear, and deduplicates explicit files")
    func configWatchPlanMatchesUpstream() {
        let project = "/watch-plan-project"
        let globalDir = "\(project)/global"
        let systemDir = "\(project)/system"
        let opencodeDir = "\(project)/.opencode"
        let directJson = "\(project)/opencode.json"
        let directJsonc = "\(project)/opencode.jsonc"
        let claudeDir = "\(project)/.claude"
        let agentsDir = "\(project)/.agents"

        let globalTarget = CoreConfigWatch.Target.directory(path: globalDir, ignore: FSPathUtil.ignoreGlobs)
        let systemTarget = CoreConfigWatch.Target.directory(path: systemDir, ignore: FSPathUtil.ignoreGlobs)
        let opencodeTarget = CoreConfigWatch.Target.directory(path: opencodeDir, ignore: FSPathUtil.ignoreGlobs)
        let projectEntries = CoreConfigWatch.Target.entries(
            path: project,
            names: [".agents", ".claude", ".opencode", "opencode.json", "opencode.jsonc", "system"]
        )

        // 1. Missing system and .opencode roots are grouped under parent `.entries` watches.
        let initialSources = CoreConfigDiscovery.Sources(
            system: CoreConfigDiscovery.DirectoryCandidate(path: abs(systemDir), present: false),
            global: abs(globalDir),
            direct: [abs(directJson), abs(directJsonc)],
            project: [CoreConfigDiscovery.DirectoryCandidate(path: abs(opencodeDir), present: false)],
            claude: [abs(claudeDir)],
            agents: [abs(agentsDir)]
        )
        let initialPlan = CoreConfigWatch.plan(initialSources)
        #expect(initialPlan[globalTarget.key] == globalTarget)
        #expect(initialPlan[systemTarget.key] == nil)
        #expect(initialPlan[opencodeTarget.key] == nil)
        #expect(initialPlan[projectEntries.key] == projectEntries)
        #expect(Set(initialPlan.values) == [globalTarget, projectEntries])

        // 2. When system and .opencode appear, directory watches are added while parent entries watch stays.
        let presentSources = CoreConfigDiscovery.Sources(
            system: CoreConfigDiscovery.DirectoryCandidate(path: abs(systemDir), present: true),
            global: abs(globalDir),
            direct: [abs(directJson), abs(directJsonc)],
            project: [CoreConfigDiscovery.DirectoryCandidate(path: abs(opencodeDir), present: true)],
            claude: [abs(claudeDir)],
            agents: [abs(agentsDir)]
        )
        let presentPlan = CoreConfigWatch.plan(presentSources)
        #expect(presentPlan[globalTarget.key] == globalTarget)
        #expect(presentPlan[systemTarget.key] == systemTarget)
        #expect(presentPlan[opencodeTarget.key] == opencodeTarget)
        #expect(presentPlan[projectEntries.key] == projectEntries)
        #expect(Set(presentPlan.values) == [globalTarget, systemTarget, opencodeTarget, projectEntries])

        // 3. Explicit files add an exact parent entries watch only when outside watched directories.
        let externalFile = "/watch-plan-external/custom.json"
        let insideGlobal = "\(globalDir)/sub/custom.json"
        let externalEntries = CoreConfigWatch.Target.entries(path: "/watch-plan-external", names: ["custom.json"])
        let extPlan = CoreConfigWatch.plan(CoreConfigDiscovery.Sources(
            global: abs(globalDir),
            explicit: abs(externalFile)
        ))
        #expect(extPlan[externalEntries.key] == externalEntries)
        #expect(Set(extPlan.values) == [globalTarget, externalEntries])

        let coveredPlan = CoreConfigWatch.plan(CoreConfigDiscovery.Sources(
            global: abs(globalDir),
            explicit: abs(insideGlobal)
        ))
        #expect(Set(coveredPlan.values) == [globalTarget])
        #expect(coveredPlan.keys.sorted() == [globalTarget.key])
    }

    @Test("CoreConfigWatch.inputs matches only config roots, config files, compatibility roots, and {file:} references")
    func configWatchInputsFiltering() async {
        let fs = InMemoryFileSystem(initialFiles: [
            "/cfg/global/opencode.json": Array("{}".utf8),
            "/cfg/secret.txt": Array("token".utf8),
        ])
        let sources = CoreConfigDiscovery.Sources(
            global: abs("/cfg/global"),
            explicit: abs("/cfg/explicit.jsonc"),
            direct: [abs("/proj/opencode.json")],
            project: [CoreConfigDiscovery.DirectoryCandidate(path: abs("/proj/.opencode"), present: true)],
            claude: [abs("/proj/.claude")],
            agents: [abs("/proj/.agents")]
        )
        let isInput = await CoreConfigWatch.inputs(
            sources: sources,
            references: ["/cfg/secret.txt"],
            fileSystem: fs
        )

        #expect(isInput("/cfg/global"))
        #expect(isInput("/cfg/global/opencode.json"))
        #expect(isInput("/cfg/global/opencode.jsonc"))
        #expect(isInput("/proj/.opencode/opencode.json"))
        #expect(isInput("/proj/.opencode"))
        #expect(isInput("/proj/opencode.json"))
        #expect(isInput("/proj/.claude"))
        #expect(isInput("/proj/.agents"))
        #expect(isInput("/cfg/explicit.jsonc"))
        #expect(isInput("/cfg/secret.txt"))

        // Unrelated files under watched directories must NOT match.
        #expect(!isInput("/cfg/global/notes.txt"))
        #expect(!isInput("/cfg/global/skills/foo/SKILL.md"))
        #expect(!isInput("/proj/.opencode/README.md"))
        #expect(!isInput("/proj/other.json"))
    }

    // MARK: - CoreConfig.Service live watching

    @Test("CoreConfig.Service coalesces edits, ignores unrelated files, tracks {file:} refs, reconciles .opencode, and stops on close")
    func configServiceLiveWatchSemantics() async throws {
        let root = "/cfg-test"
        let globalDir = "\(root)/global"
        let projectDir = "\(root)/home/repo"
        let globalFile = "\(globalDir)/opencode.json"
        let projectFile = "\(projectDir)/opencode.json"
        let refFile = "\(globalDir)/username.txt"
        let unrelatedFile = "\(globalDir)/scratch.txt"
        let dotOpencodeFile = "\(projectDir)/.opencode/opencode.json"

        let fs = InMemoryFileSystem(initialFiles: [
            globalFile: Array("""
            {
              "username": "{file:./username.txt}",
              "shell": "/bin/sh"
            }
            """.utf8),
            refFile: Array("alice".utf8),
            projectFile: Array("""
            {
              "timezone": "UTC"
            }
            """.utf8),
        ])
        try await fs.makeDirectory(at: "\(root)/home", recursive: true)
        try await fs.makeDirectory(at: projectDir, recursive: true)

        let bus = try makeBus()
        let route = OpenCodeLocation(directory: projectDir)
        let watcher = CoreFilesystem.Watcher.Service(enabled: true, native: CoreFilesystem.Watcher.inMemoryNative(fileSystem: fs))
        let config = await CoreConfig.Service(
            directory: projectDir,
            options: CoreConfig.Options(project: true, global: true, system: .disabled, claude: true),
            globalPaths: makeGlobal(root: root),
            fileSystem: fs,
            environment: DictionaryEnvironment(variables: [:], homeDirectory: "\(root)/home", temporaryDirectory: "\(root)/tmp"),
            watcher: watcher,
            bus: bus,
            location: route,
            debounce: .milliseconds(40)
        )
        defer {
            Task {
                await config.close()
                await watcher.close()
            }
        }

        // Initial entries resolve `{file:./username.txt}`.
        let initial = await config.entries()
        #expect(CoreConfig.latest(initial, \.username) == "alice")
        #expect(CoreConfig.latest(initial, \.shell) == "/bin/sh")

        // Wait for initial onReady readiness rescan to settle.
        #expect(await waitUntil { config.reloadCount >= 1 })

        // Track `config.updated` events and raw `changes()`.
        let updatedCount = Mutex(0)
        let updatedStream = bus.subscribe(types: [ConfigSchema.Event.updated.type], location: route)
        let updatedTask = Task {
            for await _ in updatedStream {
                updatedCount.withLock { $0 += 1 }
            }
        }
        let rawChanges = Mutex<[CoreConfig.WatchUpdate]>([])
        let changesStream = config.changes()
        let changesTask = Task {
            for await change in changesStream {
                rawChanges.withLock { $0.append(change) }
            }
        }
        defer {
            updatedTask.cancel()
            changesTask.cancel()
        }
        await Task.yield()

        // 1. Unrelated file inside watched global root forwards to `changes()` WITHOUT reloading or emitting `config.updated`.
        let reloadsBeforeUnrelated = config.reloadCount
        try await fs.writeFile(Array("hello".utf8), to: unrelatedFile, createDirectories: false)
        #expect(await waitUntil {
            rawChanges.withLock { list in list.contains { $0.path == unrelatedFile } }
        })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(config.reloadCount == reloadsBeforeUnrelated)
        #expect(updatedCount.withLock { $0 } == 0)

        // 2. Editing the `{file:./username.txt}` reference target triggers reload and emits 1 `config.updated`.
        try await fs.writeFile(Array("bob".utf8), to: refFile, createDirectories: false)
        #expect(await waitUntil {
            updatedCount.withLock { $0 } == 1
        })
        #expect(CoreConfig.latest(await config.entries(), \.username) == "bob")

        // 3. Burst-editing project and global config coalesces into ONE additional `config.updated`.
        let countBeforeBurst = updatedCount.withLock { $0 }
        try await fs.writeFile(Array("{\"username\":\"{file:./username.txt}\",\"shell\":\"/bin/zsh\"}".utf8), to: globalFile, createDirectories: false)
        try await fs.writeFile(Array("{\"timezone\":\"America/New_York\"}".utf8), to: projectFile, createDirectories: false)
        #expect(await waitUntil { updatedCount.withLock { $0 } == countBeforeBurst + 1 })
        try? await Task.sleep(for: .milliseconds(120))
        #expect(updatedCount.withLock { $0 } == countBeforeBurst + 1)
        let afterBurst = await config.entries()
        #expect(CoreConfig.latest(afterBurst, \.shell) == "/bin/zsh")
        #expect(CoreConfig.latest(afterBurst, \.timezone) == "America/New_York")

        // 4. Rewriting project file with identical semantics emits ZERO `config.updated`.
        let countBeforeNoOp = updatedCount.withLock { $0 }
        let reloadsBeforeNoOp = config.reloadCount
        try await fs.writeFile(Array("{\n  \"timezone\": \"America/New_York\"\n}\n".utf8), to: projectFile, createDirectories: false)
        #expect(await waitUntil { config.reloadCount > reloadsBeforeNoOp })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(updatedCount.withLock { $0 } == countBeforeNoOp)

        // 5. Creating `.opencode/opencode.json`, editing it, deleting `.opencode`, and recreating it reconciles watches.
        let countBeforeCreate = updatedCount.withLock { $0 }
        try await fs.writeFile(Array("{\"username\":\"from-dot-opencode\"}".utf8), to: dotOpencodeFile, createDirectories: true)
        #expect(await waitUntil {
            CoreConfig.latest(await config.entries(), \.username) == "from-dot-opencode"
        })
        #expect(updatedCount.withLock { $0 } >= countBeforeCreate + 1)

        try await fs.writeFile(Array("{\"username\":\"edited-dot-opencode\"}".utf8), to: dotOpencodeFile, createDirectories: false)
        #expect(await waitUntil {
            CoreConfig.latest(await config.entries(), \.username) == "edited-dot-opencode"
        })

        try await fs.remove(at: "\(projectDir)/.opencode")
        #expect(await waitUntil {
            CoreConfig.latest(await config.entries(), \.username) == "bob"
        })

        try await fs.writeFile(Array("{\"username\":\"recreated-dot-opencode\"}".utf8), to: dotOpencodeFile, createDirectories: true)
        #expect(await waitUntil {
            CoreConfig.latest(await config.entries(), \.username) == "recreated-dot-opencode"
        })

        // 6. Close stops all watches and suppresses further reloads.
        await config.close()
        #expect(config.activeWatchCount == 0)
        let reloadsAfterClose = config.reloadCount
        try await fs.writeFile(Array("{\"username\":\"post-close\"}".utf8), to: projectFile, createDirectories: false)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(config.reloadCount == reloadsAfterClose)
    }

    // MARK: - LocationWatcher, LocationWatcherPolicy, ConfigLocationWatcherPlugin, Vcs, LocationActivity

    @Test("LocationWatcher + Vcs handle git, linked worktree gitdir, hg, ignore policy updates, reentrant policy observers, and close")
    func locationWatcherAndVcsIntegration() async throws {
        // 1. Git repo: `.git/HEAD` changes emit `filesystem.changed` and drive `vcs.branch.updated`; unrelated `HEAD` ignored.
        let repo = "/vcs-repo"
        let headPath = "\(repo)/.git/HEAD"
        let unrelatedHead = "\(repo)/src/HEAD"
        let fs = InMemoryFileSystem(initialFiles: [
            headPath: Array("ref: refs/heads/main\n".utf8),
            unrelatedHead: Array("not git".utf8),
        ])
        let bus = try makeBus()
        let route = OpenCodeLocation(directory: repo)
        let watcher = CoreFilesystem.Watcher.Service(enabled: true, native: CoreFilesystem.Watcher.inMemoryNative(fileSystem: fs))
        let gitType = try #require(ProjectSchema.Vcs(rawValue: "git"))
        let vcsMeta = CoreProject.Schema.Vcs(type: gitType, store: abs("\(repo)/.git"))
        let locInfo = LocationSchema.Info(
            directory: abs(repo),
            project: LocationSchema.ProjectRef(id: ProjectID.global, directory: abs(repo), canonical: abs(repo))
        )
        let locationSvc = CoreLocation.Location.Service(info: locInfo, vcs: vcsMeta)
        let policy = CoreFilesystem.LocationWatcherPolicy.Service()
        let configTest = CoreConfig.Test(initial: [])
        let policyObserver = await CoreConfigPlugin.LocationWatcher.start(
            config: configTest,
            bus: bus,
            location: route,
            policy: policy
        )

        let vcs = CoreVcs.Vcs.Service(
            projectDirectory: abs(repo),
            detectedVcsType: "git",
            vcs: vcsMeta,
            location: route,
            bus: bus,
            fileSystem: fs
        )
        _ = try await vcs.transform { editor in
            editor.add(CoreVcs.Vcs.ProviderDefinition(
                id: "git",
                info: {
                    let text = (try? await fs.readFile(at: headPath)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let branch: String? = trimmed.hasPrefix("ref: refs/heads/")
                        ? String(trimmed.dropFirst("ref: refs/heads/".count))
                        : nil
                    return VcsSchema.Info(provider: "git", branch: VcsSchema.Branch(current: branch))
                }
            ))
        }
        #expect((await vcs.info()).branch.current == "main")

        let locWatcher = CoreFilesystem.LocationWatcher.Service(
            location: locationSvc,
            watcher: watcher,
            bus: bus,
            fileSystem: fs,
            policy: policy
        )
        locWatcher.start()
        await locWatcher.awaitReady()
        #expect(locWatcher.activePath == headPath)

        let branchEvents = Mutex<[String?]>([])
        let branchStream = bus.subscribe(types: [VcsEventSchema.BranchUpdated.type], location: route)
        let branchTask = Task {
            for await env in branchStream {
                if case .object(let obj) = env.data {
                    if case .string(let b) = obj["branch"] {
                        branchEvents.withLock { $0.append(b) }
                    } else {
                        branchEvents.withLock { $0.append(nil) }
                    }
                }
            }
        }
        defer {
            branchTask.cancel()
            Task {
                await locWatcher.close()
                await policyObserver.close()
                await vcs.close()
                await watcher.close()
            }
        }
        await Task.yield()

        // Emit an unrelated `filesystem.changed` for `/vcs-repo/src/HEAD` -> must NOT trigger branch event.
        _ = try await bus.publishRaw(
            definition: EventSchema.EphemeralDefinition<FileSystemSchema.Event.ChangedPayload>(type: FileSystemSchema.Event.changed.type).descriptor,
            data: JSONValue.object(["file": JSONValue.string(unrelatedHead), "event": JSONValue.string("change")]),
            options: CoreBus.PublishOptions(location: route)
        )
        try? await Task.sleep(for: .milliseconds(50))
        #expect(branchEvents.withLock { $0 }.isEmpty)

        // Rewrite `.git/HEAD` -> emits `vcs.branch.updated` with `"feature/watch"`.
        try await fs.writeFile(Array("ref: refs/heads/feature/watch\n".utf8), to: headPath, createDirectories: false)
        #expect(await waitUntil { branchEvents.withLock { $0 == ["feature/watch"] } })
        #expect((await vcs.info()).branch.current == "feature/watch")

        // Same branch rewrite -> no duplicate event.
        try await fs.writeFile(Array("ref: refs/heads/feature/watch\n".utf8), to: headPath, createDirectories: false)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(branchEvents.withLock { $0 == ["feature/watch"] })

        // Dynamic config `watcher.ignore: [".git"]` via `config.updated` detaches the `.git/HEAD` watch.
        await configTest.setEntries([
            .document(ConfigSchema.Document(
                path: abs("\(repo)/opencode.json"),
                info: ConfigSchema.Info(watcher: ConfigWatcherSchema.Info(ignore: [".git"]))
            ))
        ])
        _ = try await bus.publishRaw(
            definition: EventSchema.EphemeralDefinition<JSONValue>(type: ConfigSchema.Event.updated.type).descriptor,
            data: JSONValue.object([:]),
            options: CoreBus.PublishOptions(location: route)
        )
        #expect(await waitUntil { locWatcher.activePath == nil })

        // Removing `.git` from `watcher.ignore` re-attaches `.git/HEAD` watch.
        await configTest.setEntries([])
        _ = try await bus.publishRaw(
            definition: EventSchema.EphemeralDefinition<JSONValue>(type: ConfigSchema.Event.updated.type).descriptor,
            data: JSONValue.object([:]),
            options: CoreBus.PublishOptions(location: route)
        )
        #expect(await waitUntil { locWatcher.activePath == headPath })

        // 2. Mercurial repo watches `.hg/branch` and updates branch on edit.
        let hgRepo = "/hg-repo"
        let hgBranchFile = "\(hgRepo)/.hg/branch"
        let hgFS = InMemoryFileSystem(initialFiles: [
            hgBranchFile: Array("default\n".utf8),
        ])
        let hgBus = try makeBus()
        let hgRoute = OpenCodeLocation(directory: hgRepo)
        let hgWatcher = CoreFilesystem.Watcher.Service(enabled: true, native: CoreFilesystem.Watcher.inMemoryNative(fileSystem: hgFS))
        let hgType = try #require(ProjectSchema.Vcs(rawValue: "hg"))
        let hgVcsMeta = CoreProject.Schema.Vcs(type: hgType, store: abs("\(hgRepo)/.hg"))
        let hgLocSvc = CoreLocation.Location.Service(
            info: LocationSchema.Info(
                directory: abs(hgRepo),
                project: LocationSchema.ProjectRef(id: ProjectID.global, directory: abs(hgRepo), canonical: abs(hgRepo))
            ),
            vcs: hgVcsMeta
        )
        let hgVcs = CoreVcs.Vcs.Service(
            projectDirectory: abs(hgRepo),
            detectedVcsType: "hg",
            vcs: hgVcsMeta,
            location: hgRoute,
            bus: hgBus,
            fileSystem: hgFS
        )
        _ = try await hgVcs.transform { editor in
            editor.add(CoreVcs.Vcs.ProviderDefinition(
                id: "hg",
                info: {
                    let text = (try? await hgFS.readFile(at: hgBranchFile)).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    let branch = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return VcsSchema.Info(provider: "hg", branch: VcsSchema.Branch(current: branch.isEmpty ? nil : branch))
                }
            ))
        }
        let hgLocWatcher = CoreFilesystem.LocationWatcher.Service(
            location: hgLocSvc,
            watcher: hgWatcher,
            bus: hgBus,
            fileSystem: hgFS
        )
        hgLocWatcher.start()
        await hgLocWatcher.awaitReady()
        #expect(hgLocWatcher.activePath == hgBranchFile)

        let hgEvents = Mutex<[String?]>([])
        let hgStream = hgBus.subscribe(types: [VcsEventSchema.BranchUpdated.type], location: hgRoute)
        let hgTask = Task {
            for await env in hgStream {
                if case .object(let obj) = env.data, case .string(let b) = obj["branch"] {
                    hgEvents.withLock { $0.append(b) }
                }
            }
        }
        await Task.yield()
        try await hgFS.writeFile(Array("release-2.0\n".utf8), to: hgBranchFile, createDirectories: false)
        #expect(await waitUntil { hgEvents.withLock { $0 == ["release-2.0"] } })
        #expect((await hgVcs.info()).branch.current == "release-2.0")
        hgTask.cancel()
        await hgLocWatcher.close()
        await hgVcs.close()
        await hgWatcher.close()

        // 3. Linked git worktree `.git` pointer file resolves to worktree gitdir `HEAD`.
        let wtDir = "/worktrees/wt1"
        let actualGitDir = "/main-repo/.git/worktrees/wt1"
        let wtFS = InMemoryFileSystem(initialFiles: [
            "\(wtDir)/.git": Array("gitdir: \(actualGitDir)\n".utf8),
            "\(actualGitDir)/HEAD": Array("ref: refs/heads/wt-branch\n".utf8),
        ])
        let wtWatcherTest = CoreFilesystem.Watcher.Test()
        let wtLocSvc = CoreLocation.Location.Service(
            info: LocationSchema.Info(
                directory: abs(wtDir),
                project: LocationSchema.ProjectRef(id: ProjectID.global, directory: abs(wtDir), canonical: abs(wtDir))
            ),
            vcs: CoreProject.Schema.Vcs(type: gitType, store: abs("\(wtDir)/.git"))
        )
        let wtLocWatcher = CoreFilesystem.LocationWatcher.Service(
            location: wtLocSvc,
            watcher: wtWatcherTest,
            fileSystem: wtFS
        )
        wtLocWatcher.start()
        await wtLocWatcher.awaitReady()
        #expect(wtLocWatcher.activePath == "\(actualGitDir)/HEAD")
        await wtLocWatcher.close()
        #expect(await waitUntil { wtWatcherTest.activeSubscriptionCount() == 0 })

        // 4. Reentrant LocationWatcherPolicy observer ordering (matches upstream `location-watcher-policy.test.ts`).
        let reentrantPolicy = CoreFilesystem.LocationWatcherPolicy.Service()
        let observed = Mutex<[[String]]>([])
        let reentered = Mutex(false)
        let obs1 = reentrantPolicy.observe { _ in
            let first = reentered.withLock { flag -> Bool in
                if flag { return false }
                flag = true
                return true
            }
            if first {
                _ = await reentrantPolicy.transform { $0.add([".git"]) }
            }
        }
        let obs2 = reentrantPolicy.observe { ignore in
            observed.withLock { $0.append(ignore) }
        }
        _ = await reentrantPolicy.transform { $0.add(["node_modules"]) }
        #expect(reentrantPolicy.current() == ["node_modules", ".git"])
        #expect(observed.withLock { $0 } == [["node_modules", ".git"], ["node_modules", ".git"]])
        obs1.dispose()
        obs2.dispose()
    }

    @Test("CoreLocation.Activity.Service.sweep honors live experimental.location_idle_timeout config")
    func locationActivityReadsConfiguredIdleTimeout() async throws {
        let nowMs = Mutex<Int64>(10_000)
        let ref = LocationSchema.Ref(directory: abs("/idle-test"))
        let configTest = CoreConfig.Test(initial: [
            CoreConfigEntry.document(ConfigSchema.Document(
                path: abs("/idle-test/opencode.json"),
                info: ConfigSchema.Info(
                    experimental: ConfigExperimentalSchema.Info(locationIdleTimeout: .disabled)
                )
            ))
        ])
        let closed = Mutex(false)
        let serviceMap = CoreLocation.ServiceMap.Service { _, scope in
            scope.addFinalizer {
                closed.withLock { $0 = true }
            }
            return LayerNode.Output([
                CoreConfig.Service.serviceKey: configTest as any CoreConfig.Interface,
            ])
        }
        _ = try await serviceMap.get(ref)

        let activity = CoreLocation.Activity.Service(timeToLiveMs: 1_000, clock: { nowMs.withLock { $0 } })
        activity.touch(ref)

        // Advance well past default 1_000ms TTL while configured `"disabled"` -> must NOT evict.
        nowMs.withLock { $0 += 100_000 }
        let evictedDisabled = await activity.sweep(locations: serviceMap)
        #expect(evictedDisabled.isEmpty)
        #expect(serviceMap.has(ref))
        #expect(!closed.withLock { $0 })

        // Switch config to `"50ms"` -> next sweep evicts the idle Location and runs its finalizers.
        await configTest.setEntries([
            CoreConfigEntry.document(ConfigSchema.Document(
                path: abs("/idle-test/opencode.json"),
                info: ConfigSchema.Info(
                    experimental: ConfigExperimentalSchema.Info(locationIdleTimeout: .duration("50ms"))
                )
            ))
        ])
        let evictedAfterConfig = await activity.sweep(locations: serviceMap)
        #expect(evictedAfterConfig == [ref])
        #expect(!serviceMap.has(ref))
        #expect(closed.withLock { $0 })
    }
}

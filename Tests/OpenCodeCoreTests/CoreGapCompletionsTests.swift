import Testing
import OpenCodeAI
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil

@Suite("Core Wave 2 R2 Parity & Gap Completions")
struct CoreGapCompletionsTests {
    // MARK: - CoreShell.Scan POSIX / Bash / Zsh

    @Test("CoreShell.Scan.scan parses pipelines, lists, quotes, and declarations")
    func shellScanBasicPipelinesAndDeclarations() {
        let simple = CoreShell.Scan.scan("echo hello world")
        #expect(simple == .scanned(commands: [
            CoreShell.Scan.Command(
                resource: "echo hello world",
                words: ["echo", "hello", "world"],
                rawWords: ["echo", "hello", "world"]
            ),
        ]))

        let pipeline = CoreShell.Scan.scan("ls -la | grep foo && cat bar.txt || echo fail")
        guard case .scanned(let pipeCmds) = pipeline else {
            Issue.record("Expected scanned pipeline, got \(pipeline)")
            return
        }
        #expect(pipeCmds.map(\.words) == [
            ["ls", "-la"],
            ["grep", "foo"],
            ["cat", "bar.txt"],
            ["echo", "fail"],
        ])

        let decl = CoreShell.Scan.scan("export FOO=bar && echo $FOO")
        guard case .scanned(let declCmds) = decl else {
            Issue.record("Expected scanned declaration, got \(decl)")
            return
        }
        #expect(declCmds.count == 2)
        #expect(declCmds[0].declaration == true)
        #expect(declCmds[0].words == ["export", "FOO=bar"])
        #expect(declCmds[1].declaration == false)
        #expect(declCmds[1].words == ["echo", "$FOO"])

        let quoted = CoreShell.Scan.scan("echo \"hello world\" 'single quote'")
        guard case .scanned(let qCmds) = quoted else {
            Issue.record("Expected scanned quoted words, got \(quoted)")
            return
        }
        #expect(qCmds.first?.words == ["echo", "hello world", "single quote"])
        #expect(qCmds.first?.rawWords == ["echo", "\"hello world\"", "'single quote'"])
    }

    @Test("CoreShell.Scan.scan extracts nested command substitutions, redirections, and heredocs")
    func shellScanSubstitutionsRedirectionsAndHeredocs() {
        let sub = CoreShell.Scan.scan("echo $(whoami) && printf \"`id`\"")
        guard case .scanned(let subCmds) = sub else {
            Issue.record("Expected scanned command substitutions, got \(sub)")
            return
        }
        #expect(subCmds.map(\.words) == [
            ["echo", "$(whoami)"],
            ["whoami"],
            ["printf", "`id`"],
            ["id"],
        ])

        let redir = CoreShell.Scan.scan("echo a > out.txt 2>&1")
        #expect(redir == .scanned(commands: [
            CoreShell.Scan.Command(
                resource: "echo a > out.txt 2>&1",
                words: ["echo", "a"],
                rawWords: ["echo", "a"]
            ),
        ]))

        let cmdlessRedir = CoreShell.Scan.scan("> out.txt")
        #expect(cmdlessRedir == .scanned(commands: [
            CoreShell.Scan.Command(
                resource: "> out.txt",
                words: [">"],
                rawWords: [">"],
                redirectPrefixEnd: 1
            ),
        ]))

        let hd = CoreShell.Scan.scan("cat <<EOF\nhello world\nEOF")
        #expect(hd == .scanned(commands: [
            CoreShell.Scan.Command(
                resource: "cat <<EOF\nhello world\nEOF",
                words: ["cat"],
                rawWords: ["cat"]
            ),
        ]))

        let hdTabs = CoreShell.Scan.scan("cat <<-EOF\n\tindented\n\tEOF")
        guard case .scanned(let hdTabsCmds) = hdTabs else {
            Issue.record("Expected scanned tab-stripped heredoc, got \(hdTabs)")
            return
        }
        #expect(hdTabsCmds.count == 1 && hdTabsCmds[0].words == ["cat"])

        let hdExpand = CoreShell.Scan.scan("cat <<EOF\nhello $(uname)\nEOF")
        guard case .scanned(let hdExpandCmds) = hdExpand else {
            Issue.record("Expected scanned heredoc with substitution, got \(hdExpand)")
            return
        }
        #expect(hdExpandCmds.map(\.words) == [["cat"], ["uname"]])

        let hdQuoted = CoreShell.Scan.scan("cat <<'EOF'\nhello $(uname)\nEOF")
        guard case .scanned(let hdQuotedCmds) = hdQuoted else {
            Issue.record("Expected scanned quoted heredoc, got \(hdQuoted)")
            return
        }
        #expect(hdQuotedCmds.map(\.words) == [["cat"]])

        #expect(CoreShell.Scan.scan("cat <<EOF\nunterminated") == .opaque(reason: .heredoc))
    }

    @Test("CoreShell.Scan.scan handles compound commands, subshells, bash ANSI quotes, zsh syntax, and opaque reasons")
    func shellScanCompoundDialectsAndOpaqueReasons() {
        let ifRes = CoreShell.Scan.scan("if true; then echo yes; else echo no; fi")
        guard case .scanned(let ifCmds) = ifRes else {
            Issue.record("Expected scanned if, got \(ifRes)")
            return
        }
        #expect(ifCmds.map(\.words) == [["true"], ["echo", "yes"], ["echo", "no"]])

        let forRes = CoreShell.Scan.scan("for x in a b c; do echo $x; done")
        guard case .scanned(let forCmds) = forRes else {
            Issue.record("Expected scanned for, got \(forRes)")
            return
        }
        #expect(forCmds.map(\.words) == [["echo", "$x"]])

        let caseRes = CoreShell.Scan.scan("case $x in a|b) echo ab ;; *) echo other ;; esac")
        guard case .scanned(let caseCmds) = caseRes else {
            Issue.record("Expected scanned case, got \(caseRes)")
            return
        }
        #expect(caseCmds.map(\.words) == [["echo", "ab"], ["echo", "other"]])

        let subshell = CoreShell.Scan.scan("(cd /tmp && ls)")
        guard case .scanned(let subshellCmds) = subshell else {
            Issue.record("Expected scanned subshell, got \(subshell)")
            return
        }
        #expect(subshellCmds.map(\.words) == [["cd", "/tmp"], ["ls"]])

        let brace = CoreShell.Scan.scan("{ echo one; echo two; }")
        guard case .scanned(let braceCmds) = brace else {
            Issue.record("Expected scanned brace group, got \(brace)")
            return
        }
        #expect(braceCmds.map(\.words) == [["echo", "one"], ["echo", "two"]])

        #expect(CoreShell.Scan.scan("[[ -f foo && $x -eq 1 ]]", dialect: .bash) == .scanned(commands: []))
        #expect(CoreShell.Scan.scan("a=(1 2 3)", dialect: .bash) == .scanned(commands: []))

        let ansi = CoreShell.Scan.scan("echo $'hello\\nworld\\x41'", dialect: .bash)
        guard case .scanned(let ansiCmds) = ansi else {
            Issue.record("Expected scanned bash ANSI-C quote, got \(ansi)")
            return
        }
        #expect(ansiCmds.first?.words == ["echo", "hello\nworldA"])

        // Arithmetic safe vs dynamic execution
        let arith = CoreShell.Scan.scan("echo $((1 + 2))")
        guard case .scanned(let arithCmds) = arith else {
            Issue.record("Expected scanned arithmetic, got \(arith)")
            return
        }
        #expect(arithCmds.first?.words == ["echo", "$((1 + 2))"])
        #expect(CoreShell.Scan.scan("x=\"\\$(id)\"; eval $x") == .opaque(reason: .dynamicExecution))
        #expect(CoreShell.Scan.scan("alias ll='ls -la'") == .opaque(reason: .dynamicExecution))

        // Zsh dialect constructs
        #expect(CoreShell.Scan.scan("echo ${(e)foo}", dialect: .zsh) == .opaque(reason: .dynamicExecution))
        #expect(CoreShell.Scan.scan("setopt globsubst", dialect: .zsh) == .opaque(reason: .dynamicExecution))
        guard case .scanned(let zshQual) = CoreShell.Scan.scan("echo *(.)", dialect: .zsh) else {
            Issue.record("Expected scanned zsh safe glob qualifier")
            return
        }
        #expect(zshQual.first?.words == ["echo", "*(.)"])
        guard case .scanned(let zshSub) = CoreShell.Scan.scan("echo $foo[1]", dialect: .zsh) else {
            Issue.record("Expected scanned zsh subscript")
            return
        }
        #expect(zshSub.first?.words == ["echo", "$foo[1]"])

        // Opaque failure reasons
        #expect(CoreShell.Scan.scan("echo \"unterminated") == .opaque(reason: .unterminatedQuote))
        #expect(CoreShell.Scan.scan("echo trailing\\") == .opaque(reason: .unterminatedEscape))
        #expect(CoreShell.Scan.scan("echo $(") == .opaque(reason: .commandSubstitution))
        let oversized = String(repeating: "a", count: 65 * 1024)
        #expect(CoreShell.Scan.scan(oversized) == .opaque(reason: .invalidStructure))
    }

    // MARK: - CoreShell.Scan.scanPowerShell

    @Test("CoreShell.Scan.scanPowerShell scans pipelines, subexpressions, here-strings, stop-parsing, member calls, and opaque constructs")
    func shellScanPowerShell() {
        let pipe = CoreShell.Scan.scanPowerShell("Get-ChildItem | Select-Object Name")
        #expect(pipe == .scanned(commands: [
            CoreShell.Scan.Command(
                resource: "Get-ChildItem",
                words: ["Get-ChildItem"],
                rawWords: ["Get-ChildItem"],
                wordEnds: [13],
                statementHead: true
            ),
            CoreShell.Scan.Command(
                resource: "Select-Object Name",
                words: ["Select-Object", "Name"],
                rawWords: ["Select-Object", "Name"],
                wordEnds: [13, 18],
                statementHead: false
            ),
        ]))

        let semi = CoreShell.Scan.scanPowerShell("Set-Location ../other; git status --short")
        guard case .scanned(let semiCmds) = semi else {
            Issue.record("Expected scanned PowerShell list, got \(semi)")
            return
        }
        #expect(semiCmds.map(\.words) == [["Set-Location", "../other"], ["git", "status", "--short"]])
        #expect(semiCmds.allSatisfy { $0.statementHead })

        let sub = CoreShell.Scan.scanPowerShell("Write-Output \"hello $(Get-Date)\"")
        guard case .scanned(let subCmds) = sub else {
            Issue.record("Expected scanned PowerShell subexpression, got \(sub)")
            return
        }
        #expect(subCmds.map(\.words) == [["Write-Output", "hello $(Get-Date)"], ["Get-Date"]])

        let redir = CoreShell.Scan.scanPowerShell("echo foo > out.txt 2>&1")
        guard case .scanned(let redirCmds) = redir else {
            Issue.record("Expected scanned PowerShell redirect, got \(redir)")
            return
        }
        #expect(redirCmds.count == 1 && redirCmds[0].words == ["echo", "foo"])

        let stopParse = CoreShell.Scan.scanPowerShell("cmd.exe --% /c echo %PATH%")
        guard case .scanned(let spCmds) = stopParse else {
            Issue.record("Expected scanned PowerShell stop-parsing, got \(stopParse)")
            return
        }
        #expect(spCmds.first?.words == ["cmd.exe", "--%", "/c echo %PATH%"])

        let doubleHere = CoreShell.Scan.scanPowerShell("@\"\nhello $(whoami)\n\"@")
        guard case .scanned(let dhCmds) = doubleHere else {
            Issue.record("Expected scanned PowerShell double-quoted here-string, got \(doubleHere)")
            return
        }
        #expect(dhCmds.map(\.words) == [["whoami"]])

        #expect(CoreShell.Scan.scanPowerShell("@'\nliteral $(whoami)\n'@") == .scanned(commands: []))

        let methodCall = CoreShell.Scan.scanPowerShell("$obj.Method(1, 2)")
        guard case .scanned(let mcCmds) = methodCall else {
            Issue.record("Expected scanned PowerShell method call, got \(methodCall)")
            return
        }
        #expect(mcCmds.first?.words == ["$obj.Method", "(1, 2)"])

        let ifBlock = CoreShell.Scan.scanPowerShell("if ($true) { Write-Host ok }")
        guard case .scanned(let ifCmds) = ifBlock else {
            Issue.record("Expected scanned PowerShell if block, got \(ifBlock)")
            return
        }
        #expect(ifCmds.map(\.words) == [["Write-Host", "ok"]])

        let invoke = CoreShell.Scan.scanPowerShell("& 'git' status")
        guard case .scanned(let invCmds) = invoke else {
            Issue.record("Expected scanned PowerShell call operator, got \(invoke)")
            return
        }
        #expect(invCmds.first?.words == ["git", "status"])

        let comment = CoreShell.Scan.scanPowerShell("<# block comment #> Get-Process")
        guard case .scanned(let cmtCmds) = comment else {
            Issue.record("Expected scanned PowerShell block comment, got \(comment)")
            return
        }
        #expect(cmtCmds.map(\.words) == [["Get-Process"]])

        // PowerShell opaque reasons
        #expect(CoreShell.Scan.scanPowerShell("Write-Output \"unterminated") == .opaque(reason: .unterminatedQuote))
        #expect(CoreShell.Scan.scanPowerShell("Write-Output test`") == .opaque(reason: .unterminatedEscape))
        #expect(CoreShell.Scan.scanPowerShell("echo a >") == .opaque(reason: .invalidStructure))
        #expect(CoreShell.Scan.scanPowerShell("echo \u{201C}smart\u{201D}") == .opaque(reason: .invalidStructure))
    }

    // MARK: - Gate 11 Fix: V1 Permission Entries Codec

    @Test("CoreV1Config.Permission.entriesCodec decodes ordered object entries and rejects JSON arrays")
    func v1PermissionEntriesCodec() throws {
        let codec = CoreV1Config.Permission.entriesCodec(CoreV1Config.Permission.Action.self)
        let built = codec.decode(entries: [("*", .ask), ("read", .allow), ("rm*", .deny)])
        #expect(built.entries.count == 3)
        #expect(built.entries[0].key == "*" && built.entries[0].value == .ask)
        #expect(built.entries[2].key == "rm*" && built.entries[2].value == .deny)

        let dict = codec.toDictionary(built)
        #expect(dict["read"] == .allow)
        #expect(dict["rm*"] == .deny)

        let encoded = try codec.encode(built)
        let roundTripped = try codec.decode(encoded)
        #expect(roundTripped.entries.count == 3)

        #expect(throws: Error.self) {
            _ = try codec.decode(jsonString: "[\"allow\", \"deny\"]")
        }
    }

    // MARK: - Database Migrations, schemaBootstrap & Drizzle Query Builders

    @Test("Database migrations registry contains all 62 canonical definitions and executes real SQL")
    func databaseMigrationsAndSchemaBootstrap() throws {
        let all = CoreDatabaseMigration.migrations
        #expect(all.count == 62)
        #expect(Set(all.map(\.id)).count == 62)
        #expect(all.first?.id == "20260127222353_familiar_lady_ursula")
        #expect(all.last?.id == "20261116213417_automation_active_index")
        #expect(CoreDatabaseMigration.Migrations.m_20260823191254_nullable_workspace_binding.foreignKeys == false)

        // Fresh DB bootstrap via schemaBootstrap
        let db1 = try SQLiteDatabaseFactory.open(path: ":memory:")
        defer { try? db1.close() }
        try CoreDatabaseSchema.schemaBootstrap.up(db1, CoreDatabaseMigration.Context())
        let tables = try db1.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") }
        #expect(tables.contains("session_v2"))
        #expect(tables.contains("project"))
        #expect(tables.contains("automation"))

        // Incremental migration execution on a second empty DB running ALL 62 canonical migrations sequentially
        let db2 = try SQLiteDatabaseFactory.open(path: ":memory:")
        defer { try? db2.close() }
        try CoreDatabaseMigration.applyOnly(db2, input: CoreDatabaseMigration.migrations)
        let cols = try db2.query("PRAGMA table_info('project')").compactMap { $0.string("name") }
        #expect(cols.contains("commands"))
        let appliedCount = try db2.queryScalar("SELECT count(*) FROM migration")?.int64Value
        #expect(appliedCount == 62)
        let db2Tables = try db2.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0.string("name") }
        #expect(db2Tables.contains("session_v2"))
        #expect(db2Tables.contains("automation"))
        #expect(db2Tables.contains("job"))
    }

    @Test("CoreDatabaseDrizzle query builders, prepared queries, relational queries, and transactions work end-to-end")
    func databaseDrizzleMethodsEndToEnd() throws {
        let sqlite = try SQLiteDatabaseFactory.open(path: ":memory:")
        defer { try? sqlite.close() }
        _ = try sqlite.execute("CREATE TABLE items (id TEXT PRIMARY KEY, name TEXT NOT NULL, qty INTEGER NOT NULL)")
        let table = CoreDatabaseSchema.TableDescriptor(name: "items", columns: ["id", "name", "qty"])

        let driver = CoreDatabaseDrizzle.make(client: sqlite)
        #expect(CoreDatabaseDrizzle.JoinNullability.nullable.rawValue == "nullable")
        #expect(CoreDatabaseDrizzle.JoinNullability.notNull.rawValue == "not-null")

        // Insert + returning + onConflictDoNothing + onConflictDoUpdate + getSQL/toSQL/prepare/dynamic
        let inserted = try driver.insert(into: table)
            .values(["id": .text("i1"), "name": .text("alpha"), "qty": .integer(10)])
            .dynamic()
            .returning()
        #expect(inserted.count == 1)
        #expect(inserted[0].string("name") == "alpha")

        let conflictIgnore = driver.insert(into: table)
            .values(["id": .text("i1"), "name": .text("ignored"), "qty": .integer(99)])
            .onConflictDoNothing()
        #expect(conflictIgnore.toSQL().sql.contains("ON CONFLICT DO NOTHING"))
        _ = try conflictIgnore.prepare().run()

        _ = try driver.insert(into: table)
            .values(["id": .text("i1"), "name": .text("alpha-v2"), "qty": .integer(20)])
            .onConflictDoUpdate(.init(target: ["id"], setClause: "`name` = 'alpha-v2', `qty` = 20"))
            .run()

        // Insert-select SQL compilation
        let insertFromSelect = driver.insert(into: table)
            .select(driver.select(["id", "name", "qty"]).from(table).where("id = ?", parameters: [.text("none")]))
        #expect(insertFromSelect.getSQL().sql.contains("INSERT INTO `items`"))

        // Select, selectDistinct, CTE with, withCache, prepared query mapping
        let selectBuilder = driver.select(["id", "name", "qty"])
            .from(table)
            .where("qty >= ?", parameters: [.integer(10)])
            .orderBy("id ASC")
            .limit(5)
            .withCache(enabled: true, tag: "items-tag")
        #expect(selectBuilder.cacheEnabled == true)
        #expect(selectBuilder.cacheTag == "items-tag")
        let prepared = selectBuilder.prepare()
        #expect(prepared.getQuery().sql.contains("SELECT id, name, qty FROM `items`"))
        let allRows = try prepared.execute()
        #expect(allRows.count == 1)
        let mapped = prepared.mapResult(allRows)
        #expect(mapped.first?["name"] == .text("alpha-v2"))
        let mappedOne = prepared.mapGetResult(try prepared.get())
        #expect(mappedOne?["qty"] == .integer(20))
        #expect(try prepared.values().first?.count == 3)

        let cteRows = try driver.with("c AS (SELECT id, name, qty FROM items)")
            .select(["id", "name"])
            .from(CoreDatabaseSchema.TableDescriptor(name: "c", columns: ["id", "name"]))
            .all()
        #expect(cteRows.count == 1)

        let distinctRows = try driver.selectDistinct(["name"]).from(table).all()
        #expect(distinctRows.count == 1)

        // Update + orderBy + limit + toSQL + returning
        let upd = try driver.update(table)
            .set(["qty": .integer(42)])
            .where("id = ?", parameters: [.text("i1")])
            .dynamic()
        #expect(upd.getSQL().sql.contains("UPDATE `items` SET"))
        let updatedRows = try upd.returning()
        #expect(updatedRows.first?.int64("qty") == 42)
        let orderedUpd = try driver.update(table).set(["qty": .integer(43)]).orderBy("id").limit(1)
        #expect(orderedUpd.toSQL().sql.contains("ORDER BY id LIMIT 1"))

        // Count & RelationalQuery & RawQuery
        #expect(try driver.count(table).execute() == 1)
        let relBuilder = CoreDatabaseDrizzle.SQLiteEffectRelationalQueryBuilder(session: driver.session, table: table)
        #expect(try relBuilder.findMany().count == 1)
        #expect(try relBuilder.findFirst()?.string("id") == "i1")
        let relQuery = CoreDatabaseDrizzle.RelationalQuery(session: driver.session, table: table, limitCount: 1)
        #expect(relQuery.toSQL().sql.contains("FROM `items`"))
        #expect(try relQuery.execute().count == 1)

        let raw = CoreDatabaseDrizzle.RawQuery(query: .init(sql: "SELECT 1"), method: "get") { 1 }
        #expect(raw.getQuery().sql == "SELECT 1")
        #expect(raw.mapResult(try raw.execute()) == 1)

        // Session prepareOneTimeQuery / prepareOneTimeRelationalQuery / db run, all, get, values
        #expect(try driver.session.prepareOneTimeQuery("SELECT count(*) FROM items").values().first?.first == .integer(1))
        #expect(try driver.session.prepareOneTimeRelationalQuery("SELECT id FROM items").all().count == 1)
        #expect(try driver.all("SELECT id FROM items").count == 1)
        #expect(try driver.get("SELECT id FROM items")?.string("id") == "i1")
        #expect(try driver.values("SELECT id FROM items").count == 1)

        // Transaction rollback
        #expect(throws: CoreDatabaseDrizzle.TransactionRollbackError.self) {
            try driver.transaction { tx in
                _ = try tx.run("INSERT INTO items (id, name, qty) VALUES ('i2', 'beta', 5)")
                try tx.rollback()
            }
        }
        #expect(try driver.count(table).execute() == 1)

        // Delete + where + orderBy + limit + toSQL + returning
        let del = driver.delete(from: table).where("id = ?", parameters: [.text("i1")]).dynamic()
        #expect(del.toSQL().sql.contains("DELETE FROM `items`"))
        let deleted = try del.returning()
        #expect(deleted.count == 1)
        #expect(try driver.count(table).execute() == 0)
        let delLimited = driver.delete(from: table).orderBy("id").limit(1)
        #expect(delLimited.getSQL().sql.contains("ORDER BY id LIMIT 1"))
    }

    // MARK: - PTY, Watcher, Photon, VCS, Location, Schema & Error Message Parity

    @Test("PTY runtime spawners, watcher binding, and photon wasm descriptors work cleanly")
    func runtimeSpawnerAndBindingExports() throws {
        let bunProc = try CorePty.BunRuntime.spawn(
            "/bin/sh",
            args: ["-c", "echo hi"],
            opts: CorePty.Runtime.Opts(name: "xterm-256color", cols: 80, rows: 24, cwd: "/"),
            backend: .simulated(onWrite: nil)
        )
        let dataDisp = bunProc.onData { _ in }
        let exitDisp = bunProc.onExit { _ in }
        bunProc.write("hello\n")
        bunProc.resize(cols: 100, rows: 30)
        bunProc.kill(signal: "SIGTERM")
        dataDisp.dispose()
        exitDisp.dispose()

        let nodeProc = try CorePty.NodeRuntime.spawn(
            "/bin/sh",
            args: ["-c", "echo hi"],
            opts: CorePty.Runtime.Opts(name: "xterm-256color", cols: 80, rows: 24, cwd: "/"),
            backend: .simulated(onWrite: nil)
        )
        nodeProc.kill(signal: nil)

        let customEnv = DictionaryEnvironment(variables: ["OPENCODE_PARCEL_WATCHER_PATH": "/custom/watcher.node"])
        #expect(CoreFilesystem.Watcher.loadWatcherBinding(environment: customEnv) == "/custom/watcher.node")
        let defaultBinding = CoreFilesystem.Watcher.loadWatcherBinding(environment: DictionaryEnvironment(variables: [:]))
        #expect(defaultBinding.hasPrefix("@parcel/watcher-"))

        #expect(CoreIntegration.Image.Photon.bunPhotonWasmPath.hasSuffix("photon_rs_bg.wasm"))
        #expect(!CoreIntegration.Image.Photon.nodePhotonWasmPath.isEmpty)
        #expect(CoreIntegration.Image.Photon.workerdPhotonWasmPath.isEmpty)
        _ = CorePty.PersistentDaemon.ptyBinding
    }

    @Test("VCS, Location, Schema, Session, Automation, Tool re-exports and Error.message getters match upstream")
    func vcsLocationSchemaAndErrorMessages() async throws {
        // VCS exports
        let branch = VcsSchema.Branch(current: "main", defaultBranch: "main")
        let vcsInfo: CoreVcs.Vcs.Info = CoreVcs.Vcs.Info(provider: "git", branch: branch)
        let branches: CoreVcs.Vcs.BranchList = ["main", "dev"]
        let base: CoreVcs.Vcs.Base = CoreVcs.Vcs.Base(name: "main", ref: "refs/heads/main", source: .default)
        let mode: CoreVcs.Vcs.Mode = .working
        let untracked: CoreVcs.Vcs.Untracked = .files
        let fileStatus: CoreVcs.Vcs.FileStatus = CoreVcs.Vcs.FileStatus(
            file: "README.md",
            additions: .zero,
            deletions: .zero,
            status: .modified
        )
        #expect(vcsInfo.branch.current == "main")
        #expect(branches.count == 2 && base.source == .default && mode == .working && untracked == .files)
        #expect(fileStatus.file == "README.md")

        // Location & LocationServiceMap.Service.get
        let ref: CoreLocation.Location.Ref = CoreLocation.Location.Ref(directory: CoreSubsystems.AbsolutePath(rawValue: "/tmp/repo"))
        let env = CoreLocation.Location.response(
            location: LocationSchema.PublicRef(directory: ref.directory),
            data: "ok"
        )
        #expect(env.data == "ok")
        let svcMap = CoreLocation.ServiceMap.Service { _, _ in LayerNode.Output(["k": "v"]) }
        let loaded = try await svcMap.get(ref)
        #expect(loaded.get("k", as: String.self) == "v")

        // CoreSubsystems schema exports & AISDK.node
        let pos: CoreSubsystems.PositiveInt? = CoreSubsystems.PositiveInt(rawValue: 3)
        let nonNeg: CoreSubsystems.NonNegativeInt = .zero
        let rel: CoreSubsystems.RelativePath = CoreSubsystems.RelativePath(rawValue: "a/b.swift")
        let dt = CoreSubsystems.DateTimeUtcFromMillis(epochMillis: 1_700_000_000_000)
        #expect(pos?.rawValue == 3 && nonNeg.rawValue == 0 && rel.rawValue == "a/b.swift" && dt?.epochMillis == 1_700_000_000_000)
        #expect(CoreSubsystems.optional("x") == "x")
        let attach = CoreSubsystems.statics { (s: String) in s.count }("hello")
        #expect(attach.statics == 5)
        #expect(CoreProvider.AISDK.node.name == CoreProvider.AISDK.Service.serviceKey)

        // WebFetch convertHTMLToMarkdown & SessionRunnerRetry.isRetryable
        let md = CoreTool.WebFetchTool.convertHTMLToMarkdown("<h1>Title</h1><p>Hello</p>")
        #expect(md.contains("# Title") && md.contains("Hello"))
        let retryErr = AISchema.AIError(
            reason: .rateLimit(AISchema.RateLimitError(message: "rate limited"))
        )
        #expect(CoreSessionRunnerRetry.isRetryable(retryErr) == true)

        // Error.message getters across core subsystems
        let artID = CoreArtifact.ID.create()
        let provID = CoreArtifact.ProviderID(rawValue: "custom")!
        #expect(CoreArtifact.DisabledError().message.contains("experimental.artifacts"))
        #expect(CoreArtifact.NotFoundError(artifactID: artID).message == "Artifact not found: \(artID.rawValue)")
        #expect(CoreArtifact.FileMissingError(artifactID: artID, path: "a.html").message == "Artifact file not found: a.html")
        #expect(CoreArtifact.ProviderNotFoundError(providerID: provID).message == "Artifact provider not found: custom")
        #expect(CoreArtifact.InvalidError(reason: "bad").message == "bad")
        #expect(CoreArtifact.ProviderError(providerID: provID, detail: "boom").message == "Artifact provider custom failed: boom")

        let autoID = CoreAutomation.ID.create()
        #expect(CoreAutomation.NotFoundError(automationID: autoID).message == "Automation not found: \(autoID.rawValue)")
        #expect(CoreAutomation.InvalidError(reason: "bad cron").message == "bad cron")
        #expect(CoreAutomation.DisabledError().message.contains("experimental.automations"))

        let absDir = SchemaPrimitive.AbsolutePath(rawValue: "/missing")
        #expect(CoreFilesystem.DirectoryNotFoundError(directory: absDir).message == "Directory not found: /missing")
        #expect(CoreFilesystem.DirectoryAccessDeniedError(directory: absDir).message == "Access denied to directory: /missing")
        #expect(CoreFilesystem.FileWatch.DisabledError().message == "File watching is disabled")

        let formID = CoreIntegration.Form.ID.create()
        #expect(CoreIntegration.Form.NotFoundError(id: formID).message == "Form not found: \(formID.rawValue)")
        #expect(CoreIntegration.Form.AlreadySettledError(id: formID).message == "Form already settled: \(formID.rawValue)")
        #expect(CoreIntegration.Form.AlreadyExistsError(id: formID).message == "Form already exists: \(formID.rawValue)")

        #expect(CoreIntegration.Image.DecodeError(resource: "x.png").message == "Image could not be decoded: x.png")
        #expect(CoreIntegration.Image.SizeError(resource: "x.png", width: 4000, height: 3000, bytes: 99, maxWidth: 2000, maxHeight: 2000, maxBytes: 50).message.contains("4000x3000"))

        let instrKey = InstructionSchema.Key(rawValue: "opencode/rules")!
        #expect(CoreInstruction.Instructions.InitializationBlocked(keys: [instrKey]).message.contains("opencode/rules"))
        #expect(CoreInstruction.Instructions.DuplicateKeyError(key: instrKey).message == "Duplicate instruction key: opencode/rules")
        #expect(CoreIntegration.Integration.AuthorizationError().message == "Authorization failed")
        #expect(CoreIntegration.Integration.AuthorizationError(message: "expired").message == "expired")

        #expect(CoreMCP.Client.SessionExpiredError(server: "srv").message == "MCP server session expired: srv")
        #expect(CoreMCP.Registry.NotFoundError(server: CoreMCP.Registry.ServerName(rawValue: "srv")).message == "MCP server not found: srv")

        let pID = ProviderSchema.ID(rawValue: "openai")
        let mID = ModelSchema.ID(rawValue: "gpt-5")
        let vID = ModelSchema.VariantID(rawValue: "high")
        #expect(CoreModel.Resolver.VariantUnavailableError(providerID: pID, modelID: mID, variant: vID).message.contains("high"))
        #expect(CoreModel.Resolver.UnsupportedPackageError(providerID: pID, modelID: mID, package: "pkg").message.contains("pkg"))
        #expect(CoreModel.Resolver.ModelConfigurationError(providerID: pID, modelID: mID, package: "pkg", detail: "bad").message.contains("bad"))
        #expect(CoreModel.Resolver.ModelInitializationError(providerID: pID, modelID: mID, package: "pkg", phase: .`init`, detail: "fail").message.contains("fail"))
        #expect(CoreModel.Resolver.UnresolvedProviderVariablesError(providerID: pID, modelID: mID, variables: ["API_KEY"]).message.contains("API_KEY is required"))
        #expect(CoreModel.Resolver.UnsupportedCompactionError(providerID: pID, modelID: mID, route: "chat").message.contains("(chat)"))

        let permEffect: CorePermission.Effect = .allow
        #expect(permEffect == .allow)
        #expect(CorePermission.CorrectedError(feedback: "use ripgrep").message == "use ripgrep")
        #expect(CorePermission.BlockedError(rules: [], permission: "shell", resources: ["rm"]).message == "Permission denied: shell")

        let sid = SessionID.create()
        let mid = SessionMessageSchema.ID.create()
        #expect(CoreSession.InvalidListCursorError().message == "Invalid cursor")
        #expect(CoreSession.ForkEmptyError(sessionID: sid).message == "Cannot fork empty session: \(sid.rawValue)")
        #expect(CoreSession.MessageDecodeError(sessionID: sid, messageID: mid).message.contains(mid.rawValue))
        #expect(CoreSessionErrors.AgentNotFoundError(sessionID: sid, agent: "ghost").message == "Agent not found: \"ghost\"")
        #expect(CoreSessionErrors.StepFailedError(error: SessionErrorSchema.Error(type: "unknown", message: "boom")).message == "boom")
        #expect(CoreSessionRunnerModel.ModelNotSelectedError(sessionID: sid).message == "No model is available for session \(sid.rawValue)")
        #expect(CoreSessionRunnerModel.ModelUnavailableError(providerID: "azure-cognitive-services", modelID: "gpt-4").message.contains("use azure/gpt-4 instead"))

        #expect(CoreTool.QuestionTool.CancelledError().message == "The user dismissed this question")
        #expect(CoreToolOutput.ReadFilesystem.BinaryFileError(resource: "a.bin").message == "Cannot read binary file: a.bin")
        #expect(CoreToolOutput.ReadFilesystem.MediaIngestLimitError(resource: "a.png", maximumBytes: 100).message.contains("100 byte"))
        #expect(CoreToolOutput.ReadFilesystem.PathKindError(resource: "dir", expected: .file).message == "Path is not a file: dir")
        #expect(CoreToolOutput.ReadFilesystem.DirectoryOffsetError(resource: "dir").message.contains("is a directory"))

        // Snapshot ID alias check
        let snapID = CoreSnapshot.ID(rawValue: "abc123")
        #expect(snapID.rawValue == "abc123")
    }
}

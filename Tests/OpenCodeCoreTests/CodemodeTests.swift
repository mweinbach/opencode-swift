import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil
import Synchronization

@Suite("Code Mode Sandbox & Core Integration Tests")
struct CodemodeTests {
    // MARK: - 1. Language Semantics, Scoping, Closures, Destructuring & Control Flow

    @Test("JS variables, lexical closures, destructuring, spread, arrows, and implicit return")
    func jsLanguageCore() async throws {
        let result = try await CodemodeEngine.execute(.init(
            code: """
            const makeAdder = (base) => (x = 1) => base + x;
            const add10 = makeAdder(10);

            const fns = [];
            for (let i = 0; i < 3; i++) {
              fns.push(() => i * 2);
            }

            const [first, , third = 99, ...rest] = [1, 2, undefined, 4, 5];
            const { a, b: renamed, nested: { z }, ...extra } = { a: "hi", b: 42, nested: { z: true }, c: 7 };
            const merged = { ...extra, sum: add10(5) + add10(), fns: fns.map(f => f()) };

            ({ first, third, rest, a, renamed, z, merged })
            """
        ))

        guard case .success(let ok) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        guard case .object(let root) = ok.value else {
            Issue.record("Expected object result, got \(ok.value)")
            return
        }
        #expect(root["first"] == .int(1))
        #expect(root["third"] == .int(99))
        #expect(root["rest"] == .array([.int(4), .int(5)]))
        #expect(root["a"] == .string("hi"))
        #expect(root["renamed"] == .int(42))
        #expect(root["z"] == .bool(true))
        if case .object(let merged) = root["merged"] {
            #expect(merged["c"] == .int(7))
            #expect(merged["sum"] == .int(26))
            #expect(merged["fns"] == .array([.int(0), .int(2), .int(4)]))
        } else {
            Issue.record("Missing merged object")
        }
    }

    @Test("Control flow: switch, try/catch/finally, labeled break, optional chaining, and generators")
    func controlFlowAndGenerators() async throws {
        let result = try await CodemodeEngine.execute(.init(
            code: """
            function* range(n) {
              for (let i = 0; i < n; i++) {
                yield i;
              }
            }
            function* chained() {
              yield* range(3);
              yield 10;
            }

            let finallyRan = false;
            let caughtMessage = "";
            try {
              throw new TypeError("boom");
            } catch (err) {
              caughtMessage = err instanceof TypeError ? err.message : "wrong";
            } finally {
              finallyRan = true;
            }

            let found = -1;
            outer: for (let i = 0; i < 4; i++) {
              for (let j = 0; j < 4; j++) {
                if (i * 10 + j === 21) {
                  found = i * 10 + j;
                  break outer;
                }
              }
            }

            const deep = { a: { b: (x) => x + 1 } };
            const optOk = deep?.a?.b?.(41);
            const optMiss = deep?.missing?.b?.(1) ?? "fallback";

            return {
              gen: [...chained()],
              finallyRan,
              caughtMessage,
              found,
              optOk,
              optMiss,
            };
            """
        ))

        guard case .success(let ok) = result, case .object(let dict) = ok.value else {
            Issue.record("Expected success object, got \(result)")
            return
        }
        #expect(dict["gen"] == .array([.int(0), .int(1), .int(2), .int(10)]))
        #expect(dict["finallyRan"] == .bool(true))
        #expect(dict["caughtMessage"] == .string("boom"))
        #expect(dict["found"] == .int(21))
        #expect(dict["optOk"] == .int(42))
        #expect(dict["optMiss"] == .string("fallback"))
    }

    @Test("Const reassignment and unsupported syntax diagnostics (export, private class member, BigInt)")
    func syntaxAndRuntimeErrors() async throws {
        let exportRes = try await CodemodeEngine.execute(.init(code: "export const x = 1;"))
        if case .failure(let f) = exportRes {
            #expect(f.error.kind == "ParseError")
            #expect(f.error.message.contains("Exports aren't available"))
        } else {
            Issue.record("Expected ParseError for export")
        }

        let classRes = try await CodemodeEngine.execute(.init(code: "class Foo { #hidden = 1 }"))
        if case .failure(let f) = classRes {
            #expect(f.error.kind == "UnsupportedSyntax")
            #expect(f.error.suggestions?.isEmpty == false)
        } else {
            Issue.record("Expected UnsupportedSyntax for a private class member")
        }

        // Upstream compiles a BigInt literal to a TypeError thrown where it runs.
        let bigIntRes = try await CodemodeEngine.execute(.init(code: "const n = 123n;"))
        if case .failure(let f) = bigIntRes {
            #expect(f.error.kind == "ExecutionFailure")
            #expect(f.error.message.hasPrefix("TypeError: BigInt literals are not supported."))
        } else {
            Issue.record("Expected UnsupportedSyntax for BigInt")
        }

        let constRes = try await CodemodeEngine.execute(.init(code: "const x = 1; x = 2;"))
        if case .failure(let f) = constRes {
            #expect(f.error.kind == "ExecutionFailure")
            #expect(f.error.message.contains("TypeError"))
        } else {
            Issue.record("Expected TypeError for const reassignment")
        }
    }

    // MARK: - 2. Built-in Standard Library

    @Test("Built-ins: Array, String UTF-16, Map, Set, RegExp, JSON, URL, Base64, TextEncoder/Decoder")
    func standardLibraryBuiltins() async throws {
        let result = try await CodemodeEngine.execute(.init(
            code: """
            const nums = [5, 1, 4, 2, 3];
            const sorted = nums.toSorted((a, b) => a - b);
            const sum = sorted.filter(n => n % 2 === 1).reduce((a, b) => a + b, 0);

            const m = new Map([["a", 1], ["b", 2]]);
            m.set("c", 3);
            const s = new Set([1, 2, 2, 3]);

            const rx = /item-(\\d+)/gi;
            const matches = "item-10 and ITEM-20".match(rx);
            const replaced = "foo-1 bar-2".replace(/(\\w+)-(\\d+)/g, (_, w, d) => `${w.toUpperCase()}:${Number(d) * 10}`);

            const u = new URL("https://example.com/api/v1?page=2&tag=swift");
            u.searchParams.append("tag", "codemode");

            const bytes = new TextEncoder().encode("hello");
            const decoded = new TextDecoder().decode(bytes);
            const b64 = btoa("swift6");
            const roundtrip = atob(b64);

            const emojiLen = "😀".length; // UTF-16 surrogate pair == 2
            const parsedJson = JSON.parse(JSON.stringify({ ok: true, n: 7 }));

            return {
              sorted,
              sum,
              mapSize: m.size,
              mapB: m.get("b"),
              setValues: [...s],
              matches,
              replaced,
              host: u.host,
              tags: u.searchParams.getAll("tag"),
              decoded,
              b64,
              roundtrip,
              emojiLen,
              parsedJson,
            };
            """
        ))

        guard case .success(let ok) = result, case .object(let d) = ok.value else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(d["sorted"] == .array([.int(1), .int(2), .int(3), .int(4), .int(5)]))
        #expect(d["sum"] == .int(9))
        #expect(d["mapSize"] == .int(3))
        #expect(d["mapB"] == .int(2))
        #expect(d["setValues"] == .array([.int(1), .int(2), .int(3)]))
        #expect(d["matches"] == .array([.string("item-10"), .string("ITEM-20")]))
        #expect(d["replaced"] == .string("FOO:10 BAR:20"))
        #expect(d["host"] == .string("example.com"))
        #expect(d["tags"] == .array([.string("swift"), .string("codemode")]))
        #expect(d["decoded"] == .string("hello"))
        #expect(d["b64"] == .string("c3dpZnQ2"))
        #expect(d["roundtrip"] == .string("swift6"))
        #expect(d["emojiLen"] == .int(2))
        #expect(d["parsedJson"] == .object(["n": .int(7), "ok": .bool(true)]))
    }

    // MARK: - 3. Tool Chaining, Concurrent Promise.allSettled, Bracket Notation & Search

    @Test("Tool chaining, bracket notation, and concurrent Promise.allSettled execution")
    func toolChainingAndAllSettledConcurrency() async throws {
        let activeCount = Mutex<Int>(0)
        let peakConcurrency = Mutex<Int>(0)

        let tools: CodemodeEngine.Tools = [
            "github": .namespace(CodemodeEngine.Namespace.make(.init(
                description: "GitHub issue tracking tools",
                tools: [
                    "list_issues": .tool(CodemodeEngine.Tool.make(.init(
                        description: "List repository issues",
                        input: ["type": .string("object"), "properties": .object(["repo": .object(["type": .string("string")])])],
                        output: ["type": .string("array")],
                        execute: { _, _ in
                            .array([
                                .object(["id": .int(1), "title": .string("Alpha")]),
                                .object(["id": .int(2), "title": .string("Beta")]),
                                .object(["id": .int(3), "title": .string("Broken")]),
                            ])
                        }
                    ))),
                    "get-issue": .tool(CodemodeEngine.Tool.make(.init(
                        description: "Fetch issue details by id",
                        input: ["type": .string("object"), "properties": .object(["id": .object(["type": .string("integer")])])],
                        output: ["type": .string("object")],
                        execute: { input, _ in
                            let current = activeCount.withLock { c -> Int in c += 1; return c }
                            peakConcurrency.withLock { p in if current > p { p = current } }
                            await CodemodeTestHelper.sleepMs(25)
                            activeCount.withLock { $0 -= 1 }

                            guard case .object(let d) = input, let idVal = d["id"] else {
                                throw CodemodeEngine.toolError("Missing id")
                            }
                            if idVal == .int(3) {
                                throw CodemodeEngine.toolError("Issue 3 not found")
                            }
                            return .object(["id": idVal, "status": .string("open")])
                        }
                    ))),
                ]
            ))),
        ]

        let result = try await CodemodeEngine.execute(.init(
            code: """
            const issues = await tools.github.list_issues({ repo: "swift-opencode" });
            const settled = await Promise.allSettled(
              issues.map((issue) => tools.github["get-issue"]({ id: issue.id }))
            );
            return {
              count: settled.length,
              fulfilledIds: settled.filter(r => r.status === "fulfilled").map(r => r.value.id),
              rejectedMessages: settled.filter(r => r.status === "rejected").map(r => r.reason.message),
            };
            """,
            tools: tools
        ))

        guard case .success(let ok) = result, case .object(let dict) = ok.value else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(dict["count"] == .int(3))
        #expect(dict["fulfilledIds"] == .array([.int(1), .int(2)]))
        #expect(dict["rejectedMessages"] == .array([.string("Issue 3 not found")]))
        #expect(ok.toolCalls.count == 4)
        #expect(peakConcurrency.withLock { $0 } >= 2)
    }

    @Test("Global search(...) BM25 ranking, pagination, namespace scoping, and tools.search alias")
    func searchCatalogAndPagination() async throws {
        let noop: CodemodeEngine.Tool.ExecuteFn = { _, _ in .null }
        let tools: CodemodeEngine.Tools = [
            "github": .namespace(CodemodeEngine.Namespace.make(.init(
                description: "GitHub API",
                tools: [
                    "list_issues": .tool(CodemodeEngine.Tool.make(.init(description: "List issues in a repo", execute: noop))),
                    "create_issue": .tool(CodemodeEngine.Tool.make(.init(description: "Create a new issue", execute: noop))),
                    "list_pull_requests": .tool(CodemodeEngine.Tool.make(.init(description: "List pull requests", execute: noop))),
                ]
            ))),
            "slack": .namespace(CodemodeEngine.Namespace.make(.init(
                description: "Slack workspace messaging",
                tools: [
                    "post-message": .tool(CodemodeEngine.Tool.make(.init(description: "Post a message to a channel", execute: noop))),
                ]
            ))),
        ]

        let result = try await CodemodeEngine.execute(.init(
            code: """
            const q1 = search("issues");
            const page1 = await search({ namespace: "github", limit: 2, offset: 0 });
            const page2 = await tools.search({ namespace: "github", limit: 2, offset: page1.next.offset });
            const exact = search('tools.slack["post-message"]');
            return {
              q1Paths: q1.items.map(i => i.path),
              p1Count: page1.items.length,
              p1Remaining: page1.remaining,
              p2Count: page2.items.length,
              p2Next: page2.next,
              exactPath: exact.items[0]?.path,
            };
            """,
            tools: tools
        ))

        guard case .success(let ok) = result, case .object(let dict) = ok.value else {
            Issue.record("Expected success, got \(result)")
            return
        }
        if case .array(let q1Paths) = dict["q1Paths"] {
            #expect(q1Paths.contains(.string("tools.github.list_issues")))
            #expect(q1Paths.contains(.string("tools.github.create_issue")))
        } else {
            Issue.record("Expected q1Paths array")
        }
        #expect(dict["p1Count"] == .int(2))
        #expect(dict["p1Remaining"] == .int(1))
        #expect(dict["p2Count"] == .int(1))
        #expect(dict["p2Next"] == .null)
        #expect(dict["exactPath"] == .string(#"tools.slack["post-message"]"#))
    }

    @Test("Unknown tool suggestions, tool call limits, and before/after hooks")
    func unknownToolLimitsAndHooks() async throws {
        let hookEvents = Mutex<[String]>([])
        let tools: CodemodeEngine.Tools = [
            "math": .group([
                "add": .tool(CodemodeEngine.Tool.make(.init(
                    description: "Add two numbers",
                    execute: { input, _ in
                        guard case .object(let d) = input,
                              case .int(let a) = d["a"],
                              case .int(let b) = d["b"]
                        else { return .int(0) }
                        return .int(a + b)
                    }
                ))),
            ]),
        ]

        // 1. Typo suggestion (stems "adds" -> "add") & calling a namespace directly
        let typoRes = try await CodemodeEngine.execute(.init(
            code: "await tools.math.adds({ a: 1, b: 2 })",
            tools: tools
        ))
        if case .failure(let f) = typoRes {
            #expect(f.error.kind == "UnknownTool")
            #expect(f.error.message.contains("tools.math.add"))
        } else {
            Issue.record("Expected UnknownTool failure, got \(typoRes)")
        }

        let nsCallRes = try await CodemodeEngine.execute(.init(
            code: "await tools.math()",
            tools: tools
        ))
        if case .failure(let f) = nsCallRes {
            #expect(f.error.kind == "UnknownTool")
            #expect(f.error.message.contains("is a namespace"))
            #expect(f.error.message.contains("tools.math.add"))
        } else {
            Issue.record("Expected UnknownTool failure for namespace call, got \(nsCallRes)")
        }

        // 2. maxToolCalls limit & hooks
        let hooks = CodemodeEngine.ToolRuntime.Hooks(
            toolBefore: { inv in hookEvents.withLock { $0.append("before:\(inv.name)") } },
            toolAfter: { inv, res in
                let tag = if case .success = res { "ok" } else { "err" }
                hookEvents.withLock { $0.append("after:\(inv.name):\(tag)") }
            }
        )
        let limitRes = try await CodemodeEngine.execute(.init(
            code: """
            const a = await tools.math.add({ a: 1, b: 2 });
            const b = await tools.math.add({ a: 3, b: 4 });
            return a + b;
            """,
            tools: tools,
            hooks: hooks,
            limits: .init(maxToolCalls: 1)
        ))
        if case .failure(let f) = limitRes {
            #expect(f.error.kind == "ToolCallLimitExceeded")
            #expect(f.toolCalls.count == 1)
        } else {
            Issue.record("Expected ToolCallLimitExceeded, got \(limitRes)")
        }
        #expect(hookEvents.withLock { $0 } == ["before:math.add", "after:math.add:ok"])
    }

    // MARK: - 4. Step Limit Enforcement, Output Bounding, Console & Warning Formatting

    @Test("Step limit halts infinite loops deterministically")
    func stepLimitEnforcement() async throws {
        let result = try await CodemodeEngine.execute(.init(
            code: "let i = 0; while (true) { i++; } return i;",
            limits: .init(maxSteps: 500)
        ))
        guard case .failure(let f) = result else {
            Issue.record("Expected step limit failure, got \(result)")
            return
        }
        #expect(f.error.kind == "ExecutionFailure")
        #expect(f.error.message.contains("maximum step limit"))
    }

    @Test("Console logs, unawaited promise warnings, output bounding, and OpenCodeUtil.formatExecuteOutput compatibility")
    func consoleLogsWarningsAndFormatExecuteOutput() async throws {
        let slowTool: CodemodeEngine.Tool.ExecuteFn = { _, _ in
            await CodemodeTestHelper.sleepMs(200)
            return .string("done")
        }
        let tools: CodemodeEngine.Tools = [
            "slow": .tool(CodemodeEngine.Tool.make(.init(description: "Slow op", execute: slowTool))),
        ]

        let result = try await CodemodeEngine.execute(.init(
            code: """
            console.log("starting", 1);
            console.warn("careful");
            console.error("oops");
            tools.slow(); // intentionally unawaited -> interrupted silently, as upstream does
            Promise.reject(new Error("never handled")); // an unhandled rejection is a warning
            return { answer: 42, items: ["a", "b"] };
            """,
            tools: tools
        ))

        guard case .success(let ok) = result else {
            Issue.record("Expected success, got \(result)")
            return
        }
        #expect(ok.logs == ["starting 1", "[warn] careful", "[error] oops"])
        #expect(ok.warnings?.map(\.message) == ["Unhandled rejection from an un-awaited promise: Error: never handled"])

        let rawFormatted = result.formattedOutput()
        let pretty = formatExecuteOutput(rawFormatted)
        #expect(pretty.json != nil)
        #expect(pretty.json?.contains("\"answer\": 42") == true)
        #expect(pretty.rest?.contains("Warnings:\n") == true)
        #expect(pretty.rest?.contains("Logs:\nstarting 1\n[warn] careful\n[error] oops") == true)

        // Output byte budget truncation
        let bounded = try await CodemodeEngine.execute(.init(
            code: """
            console.log("line-one");
            console.log("line-two-very-long-message");
            return { payload: "x".repeat(200) };
            """,
            limits: .init(maxOutputBytes: 40)
        ))
        guard case .success(let truncOk) = bounded else {
            Issue.record("Expected truncated success, got \(bounded)")
            return
        }
        #expect(truncOk.truncated == true)
        if case .string(let s) = truncOk.value {
            #expect(s.contains("[result truncated:"))
        } else {
            Issue.record("Expected truncated string value, got \(truncOk.value)")
        }
    }

    // MARK: - 5. Static AST Tool Scanner (scanTools)

    @Test("scanTools extracts static paths and rejects dynamic brackets, aliasing, and imports")
    func staticScanTools() {
        let ok = CodemodeEngine.scanTools("""
        const a = await tools.github.list_issues({ repo: "x" });
        const b = await tools.slack["post-message"]({ channel: "general" });
        const c = await tools.github.list_issues({ repo: "y" });
        function local(tools) { return tools[0]; } // shadowed parameter is allowed
        return [a, b, c];
        """)
        #expect((try? ok.get()) == ["github.list_issues", "slack.post-message"])

        let dyn = CodemodeEngine.scanTools("const k = 'x'; await tools.github[k]();")
        if case .failure(let diag) = dyn {
            #expect(diag.kind == "UnsupportedSyntax")
            #expect(diag.message.contains("dynamic bracket"))
        } else {
            Issue.record("Expected failure on dynamic bracket access")
        }

        let alias = CodemodeEngine.scanTools("const t = tools; await t.github.list();")
        if case .failure(let diag) = alias {
            #expect(diag.kind == "UnsupportedSyntax")
            #expect(diag.message.contains("alias or pass"))
        } else {
            Issue.record("Expected failure on aliasing tools")
        }

        let imp = CodemodeEngine.scanTools(#"import t from "tools";"#)
        if case .failure(let diag) = imp {
            #expect(diag.kind == "UnsupportedSyntax")
            #expect(diag.message.contains("import or require"))
        } else {
            Issue.record("Expected failure on importing tools")
        }
    }

    // MARK: - 6. OpenAPI Spec Compiler via Injectable HTTPTransport

    @Test("OpenAPI fromSpec builds runnable sandbox tools strictly through HTTPTransport")
    func openAPIFromSpecAndInvoke() async throws {
        let transport = CodemodeTestHelper.MockHTTPTransport { req in
            CodemodeTestHelper.makeResponse(
                status: 200,
                body: #"[{"id":101,"title":"Port codemode"}]"#
            )
        }

        let compiled = CodemodeEngine.OpenAPI.fromSpec(.init(
            spec: CodemodeTestHelper.makeSampleOpenAPISpec(),
            authResolve: { _ in .bearer(token: "secret-tok") },
            transport: transport
        ))
        #expect(compiled.skipped.count == 1)
        #expect(compiled.skipped[0].reason.contains("SSE"))

        let result = try await CodemodeEngine.execute(.init(
            code: """
            const list = await tools.issues.list({ owner: "anomalyco", state: "open" });
            return list.map(i => `${i.id}:${i.title}`);
            """,
            tools: compiled.tools
        ))
        guard case .success(let ok) = result else {
            Issue.record("Expected OpenAPI tool success, got \(result)")
            return
        }
        #expect(ok.value == .array([.string("101:Port codemode")]))
        #expect(transport.recordedRequests.count == 1)
        #expect(transport.recordedRequests[0].url == "https://api.example.test/v1/repos/anomalyco/issues?state=open")
        #expect(transport.recordedRequests[0].headers["authorization"] == "Bearer secret-tok")
    }

    // MARK: - 7. CoreCodemode Integration (Fetch, Path, Bun, Catalog, Instructions, Job, Tool.create)

    @Test("CoreCodemode.Fetch routes via HTTPTransport, enforces permissions, redirects, and blocks file:/credentials")
    func coreCodemodeFetch() async throws {
        let permChecks = Mutex<[String]>([])
        let transport = CodemodeTestHelper.MockHTTPTransport { req in
            if req.url == "https://a.example/start" {
                return CodemodeTestHelper.makeResponse(
                    status: 302,
                    headers: ["location": "https://b.example/final"],
                    body: ""
                )
            }
            return CodemodeTestHelper.makeResponse(
                status: 200,
                headers: ["content-type": "application/json", "x-hop": "final"],
                body: #"{"ok":true,"method":"\#(req.method)"}"#
            )
        }
        let permission = CoreCodemode.PermissionHook(
            assertAllowed: { req in
                permChecks.withLock { $0.append("allow:\(req.action):\(req.resources.first ?? "")") }
                if req.resources.first?.contains("denied.example") == true {
                    throw CoreCodemode.PermissionRejectedError(message: "Denied", feedback: "Do not access denied.example")
                }
            },
            assertNotDenied: { req in
                permChecks.withLock { $0.append("hop:\(req.action):\(req.resources.first ?? "")") }
            }
        )

        let ctx = CodemodeTestHelper.makeToolContext()
        let execTool = CoreCodemode.Tool.create(
            inventory: .init(tools: [:]),
            transport: transport,
            permission: permission
        )

        // 1. Redirect: POST -> 302 -> GET on another origin, strips Authorization header
        let redirectResult = try await execTool.execute(.init(code: """
        const res = await fetch("https://a.example/start#frag", {
          method: "POST",
          headers: { authorization: "Bearer topsecret" },
          body: "payload",
        });
        const data = await res.json();
        return { status: res.status, redirected: res.redirected, url: res.url, xHop: res.headers.get("x-hop"), data };
        """), ctx)

        #expect(redirectResult.metadata?["error"] == nil)
        let outText = redirectResult.output?.output ?? ""
        let parsedPretty = formatExecuteOutput(outText)
        #expect(parsedPretty.json?.contains("\"redirected\": true") == true)
        #expect(parsedPretty.json?.contains("\"method\": \"GET\"") == true)
        #expect(transport.recordedRequests.count == 2)
        #expect(transport.recordedRequests[0].headers["authorization"] == "Bearer topsecret")
        #expect(transport.recordedRequests[1].headers["authorization"] == nil)
        #expect(transport.recordedRequests[1].method == "GET")
        #expect(permChecks.withLock { $0 } == [
            "allow:webfetch:https://a.example/start",
            "hop:webfetch:https://b.example/final",
        ])

        // 2. Reject file: protocol, credentials in URL, and permission rejection feedback
        let securityResult = try await execTool.execute(.init(code: """
        const errors = [];
        for (const u of ["file:///etc/passwd", "https://user:pass@example.com/", "https://denied.example/secret"]) {
          try { await fetch(u); } catch (e) { errors.push(e.message); }
        }
        return errors;
        """), ctx)
        let secOut = securityResult.output?.output ?? ""
        #expect(secOut.contains("filesystem access"))
        #expect(secOut.contains("credentials in the URL"))
        #expect(secOut.contains("The user rejected fetching https://denied.example/secret: Do not access denied.example"))
    }

    @Test("CoreCodemode full mode with Path + Bun (InMemoryFileSystem), file attachments, Catalog, Instructions & Job")
    func coreCodemodeFullIntegration() async throws {
        let fs = InMemoryFileSystem(initialFiles: [
            "/workspace/hello.txt": CodemodeTestHelper.utf8Bytes("hello from memfs"),
            "/workspace/app.swift": CodemodeTestHelper.utf8Bytes("let x = 1"),
        ])
        let transport = CodemodeTestHelper.MockHTTPTransport { _ in
            CodemodeTestHelper.makeResponse(status: 200, body: "{}")
        }
        let services = CoreCodemode.Tool.services(
            location: OpenCodeLocation(directory: "/workspace"),
            fileSystem: fs
        )

        let inventory = CoreCodemode.Tool.Inventory(
            tools: [
                "screenshot": CoreCodemode.Tool.ToolRegistration(
                    name: "screenshot",
                    description: "Capture PNG screenshot",
                    options: ToolSchema.Options(namespace: "browser", pinned: true),
                    execute: { _, _ in
                        ToolSchema.Result(
                            output: .object(["captured": .bool(true)]),
                            content: .parts([
                                .text(.init(text: "captured")),
                                .file(.init(uri: "data:image/png;base64,iVBORw==", mime: "image/png", name: "screen.png")),
                            ])
                        )
                    }
                ),
                "click": CoreCodemode.Tool.ToolRegistration(
                    name: "click",
                    description: "Click a CSS selector",
                    options: ToolSchema.Options(namespace: "browser"),
                    execute: { _, _ in ToolSchema.Result(output: .bool(true)) }
                ),
            ],
            namespaces: [
                "browser": ToolSchema.Namespace(name: "browser", description: "Desktop browser controls"),
            ]
        )

        // Catalog & Instructions
        let catInv = CoreCodemode.Tool.catalog(inventory)
        let summary = CoreCodemode.Catalog.summarize(catInv)
        #expect(summary.total == 2)
        let rendered = CoreCodemode.Instructions.render(summary)
        #expect(rendered.contains("# Code Mode"))
        #expect(rendered.contains("- browser (2 tools) // Desktop browser controls"))
        #expect(rendered.contains("tools.browser.screenshot"))

        // Partial catalog delta update
        let partialSummary = CoreCodemode.Catalog.summarize(catInv, options: .init(budget: 40))
        let partialRendered = CoreCodemode.Instructions.render(partialSummary)
        #expect(partialRendered.contains("The catalog is partial."))
        #expect(partialRendered.contains("search(query:"))

        let delta = CoreCodemode.Instructions.update(
            previous: CoreCodemode.Catalog.Summary(total: 1, namespaces: [
                .init(name: "browser", description: "Desktop browser controls", tools: ["browser.screenshot"], entries: [
                    .init(path: "browser.screenshot", line: "  - tools.browser.screenshot(): Promise<unknown>"),
                ]),
            ]),
            current: summary,
            lookup: CoreCodemode.Catalog.lookup(catInv)
        )
        #expect(delta?.contains("New tools are available") == true)

        // Job notice formatting
        let runningNotice = CoreCodemode.Job.notice(.init(id: "cm_1", status: "running"))
        #expect(runningNotice.text == "<background-result kind=\"codemode\" id=\"cm_1\" state=\"cancelled\">\nInterrupted by server restart.\n</background-result>")
        #expect(runningNotice.description == "Script")
        let doneNotice = CoreCodemode.Job.notice(.init(id: "cm_2", status: "completed", output: "ok"))
        #expect(doneNotice.text == "<background-result kind=\"codemode\" id=\"cm_2\" state=\"completed\">\nok\n</background-result>")

        // Full `execute` tool run using Bun.file, Bun.write, Bun.Glob, path, and browser.screenshot attachment
        let progressSnapshots = Mutex<Int>(0)
        let ctx = CodemodeTestHelper.makeToolContext { _ in
            progressSnapshots.withLock { $0 += 1 }
        }
        let execTool = CoreCodemode.Tool.create(
            inventory: inventory,
            transport: transport,
            services: services
        )
        let execResult = try await execTool.execute(.init(code: """
        import p from "node:path";
        const content = await Bun.file("hello.txt").text();
        await Bun.write("out.txt", content.toUpperCase());
        const saved = await Bun.file("out.txt").text();
        const glob = new Bun.Glob("*.swift");
        const swiftFiles = glob.scan();
        const shot = await tools.browser.screenshot();
        return {
          resolved: p.resolve("sub", "file.ts"),
          saved,
          swiftFiles,
          shot,
        };
        """), ctx)

        #expect(execResult.metadata?["error"] == nil)
        #expect(execResult.output?.files.count == 1)
        #expect(execResult.output?.files.first?.mime == "image/png")
        #expect(execResult.output?.files.first?.name == "screen.png")
        #expect(execResult.output?.toolCalls.contains(where: { $0.tool == "browser.screenshot" && $0.status == "completed" }) == true)
        #expect(progressSnapshots.withLock { $0 } >= 2)
        let text = execResult.output?.output ?? ""
        #expect(text.contains("/workspace/sub/file.ts"))
        #expect(text.contains("HELLO FROM MEMFS"))
        #expect(text.contains("app.swift"))

        // Verify persisted write in InMemoryFileSystem
        let persisted = try await fs.readFile(at: "/workspace/out.txt")
        #expect(CodemodeTestHelper.stringFromUTF8(persisted) == "HELLO FROM MEMFS")
    }

    @Test("Snapshot serialization round-trip (toBytes / fromBytes / validate / header)")
    func snapshotRoundTrip() throws {
        let snap = CodemodeLanguage.Snapshot(
            format: CodemodeLanguage.FORMAT,
            header: CodemodeLanguage.Header(
                build: CodemodeLanguage.buildId(),
                hosts: CodemodeLanguage.snapshotHash("hosts"),
                runId: "run-123",
                sources: [.init(id: "main", code: "return 42;", hash: CodemodeLanguage.snapshotHash("return 42;"), bytecode: "0000")],
                limits: .init(timeoutMs: 5000, maxOutputBytes: 4096),
                budget: .init(activeMs: 12),
                metadata: .object(["calls": .array([])])
            ),
            roots: [.null, .null, .null],
            records: []
        )
        let bytes = try CodemodeLanguage.toBytes(snap)
        let restored = try CodemodeLanguage.fromBytes(bytes)
        #expect(restored == snap)
        let hdr = try CodemodeLanguage.header(restored)
        #expect(hdr.runId == "run-123")
        #expect(hdr.limits.timeoutMs == 5000)
    }

    @Test("Freeform string tool shorthand, Promise combinators, try/catch recovery, timeoutMs, and CoreCodemode.Tool.check")
    func advancedPromisesFreeformTimeoutAndCheck() async throws {
        // 1. Freeform tool string parameter shorthand + try/catch recovery of rejected tool call
        let tools: CodemodeEngine.Tools = [
            "patch": .tool(CodemodeEngine.Tool.make(.init(
                description: "Apply patch text",
                input: [
                    "type": .string("object"),
                    "properties": .object(["patchText": .object(["type": .string("string")])]),
                    "required": .array([.string("patchText")]),
                ],
                freeform: true,
                output: ["type": .string("string")],
                execute: { input, _ in
                    guard case .object(let d) = input, case .string(let txt) = d["patchText"] else {
                        throw CodemodeEngine.toolError("Missing patchText")
                    }
                    return .string("applied:\(txt)")
                }
            ))),
            "fail": .tool(CodemodeEngine.Tool.make(.init(
                description: "Always fails",
                execute: { _, _ in throw CodemodeEngine.toolError("intentional failure") }
            ))),
        ]

        let combined = try await CodemodeEngine.execute(.init(
            code: """
            const applied = await tools.patch("+++ a.swift");
            let recovered = "";
            try {
              await tools.fail();
            } catch (err) {
              recovered = err.message;
            }
            const allOk = await Promise.all([Promise.resolve(1), Promise.try(() => 2)]);
            const raceOk = await Promise.race([Promise.resolve("fast"), new Promise(() => {})]);
            const anyOk = await Promise.any([Promise.reject("no"), Promise.resolve("yes")]);
            let aggCount = 0;
            try {
              await Promise.any([Promise.reject("e1"), Promise.reject("e2")]);
            } catch (agg) {
              aggCount = agg instanceof AggregateError ? agg.errors.length : -1;
            }
            const wr = Promise.withResolvers();
            wr.resolve(99);
            const wrVal = await wr.promise;
            return { applied, recovered, allOk, raceOk, anyOk, aggCount, wrVal };
            """,
            tools: tools
        ))

        guard case .success(let ok) = combined, case .object(let d) = ok.value else {
            Issue.record("Expected success, got \(combined)")
            return
        }
        #expect(d["applied"] == .string("applied:+++ a.swift"))
        #expect(d["recovered"] == .string("intentional failure"))
        #expect(d["allOk"] == .array([.int(1), .int(2)]))
        #expect(d["raceOk"] == .string("fast"))
        #expect(d["anyOk"] == .string("yes"))
        #expect(d["aggCount"] == .int(2))
        #expect(d["wrVal"] == .int(99))

        // 2. Wall-clock timeoutMs enforcement
        let slowTools: CodemodeEngine.Tools = [
            "wait": .tool(CodemodeEngine.Tool.make(.init(
                description: "Sleeps",
                execute: { _, _ in
                    await CodemodeTestHelper.sleepMs(300)
                    return .string("late")
                }
            ))),
        ]
        let timeoutRes = try await CodemodeEngine.execute(.init(
            code: "return await tools.wait();",
            tools: slowTools,
            limits: .init(timeoutMs: 30)
        ))
        if case .failure(let f) = timeoutRes {
            #expect(f.error.kind == "TimeoutExceeded")
        } else {
            Issue.record("Expected TimeoutExceeded, got \(timeoutRes)")
        }

        // 3. CoreCodemode.Tool.check with outer bindings and no fetch
        let inv = CoreCodemode.Tool.Inventory(tools: [
            "double": CoreCodemode.Tool.ToolRegistration(
                name: "double",
                description: "Double a number",
                execute: { input, _ in
                    if case .object(let m) = input, case .int(let n) = m["n"] {
                        return ToolSchema.Result(output: .int(n * 2))
                    }
                    return ToolSchema.Result(output: .int(0))
                }
            ),
        ])
        let checkRes = try await CoreCodemode.Tool.check(
            inventory: inv,
            code: "return { doubled: await tools.double({ n: base }), hasFetch: typeof fetch };",
            bindings: ["base": .int(21)],
            executeTool: { _, reg, input in try await reg.execute(input, CodemodeTestHelper.makeToolContext()) }
        )
        guard case .success(let chkOk) = checkRes, case .object(let chkDict) = chkOk.value else {
            Issue.record("Expected check success, got \(checkRes)")
            return
        }
        #expect(chkDict["doubled"] == .int(42))
        #expect(chkDict["hasFetch"] == .string("undefined"))
    }

    @Test("CoreCodemode.Fetch rejects redirect loops exceeding MAX_REDIRECTS")
    func coreCodemodeFetchTooManyRedirects() async throws {
        let transport = CodemodeTestHelper.MockHTTPTransport { req in
            CodemodeTestHelper.makeResponse(
                status: 302,
                headers: ["location": req.url],
                body: ""
            )
        }
        let execTool = CoreCodemode.Tool.create(inventory: .init(tools: [:]), transport: transport)
        let res = try await execTool.execute(
            .init(code: #"await fetch("https://loop.example/step")"#),
            CodemodeTestHelper.makeToolContext()
        )
        #expect(res.metadata?["error"] == .bool(true))
        #expect(res.output?.output.contains("Too many redirects (more than \(CoreCodemode.Fetch.MAX_REDIRECTS))") == true)
    }
}

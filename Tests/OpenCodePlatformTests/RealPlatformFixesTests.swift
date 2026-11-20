import Synchronization
import Testing
import OpenCodePlatform
import OpenCodeUtil

private struct RecordingProcessSpawner: ProcessSpawner {
    let handler: @Sendable (ProcessSpec) async throws -> ProcessOutput

    func run(_ spec: ProcessSpec) async throws -> ProcessOutput {
        try await handler(spec)
    }
}

@Suite("Real Platform Runtime Fixes Tests")
struct RealPlatformFixesTests {

    // MARK: - 1. LayerNodePlatform.httpFetch & httpClient -> URLSessionHTTPTransport.shared

    @Test("LayerNodePlatform.httpClient resolves to URLSessionHTTPTransport on host OSes and respects custom fetch overrides")
    func layerNodePlatformResolvesToRealURLSessionTransport() async throws {
        let scope = LayerNode.ResourceScope()
        defer { Task { await scope.close() } }

        // Default graph resolves httpClient directly to URLSessionHTTPTransport.shared
        let compiledDefault = try LayerNode.compile(LayerNodePlatform.httpClient)
        let builtDefault = try await compiledDefault.build(scope: scope)
        let transport = try #require(
            builtDefault.get(LayerNodePlatform.httpClientKey, as: (any HTTPTransport).self)
        )
        #if !os(WASI)
        #expect(transport is URLSessionHTTPTransport)
        let urlSessionTransport = try #require(transport as? URLSessionHTTPTransport)
        #expect(urlSessionTransport === URLSessionHTTPTransport.shared)

        // Default fetchLayer() also dispatches through real URLSessionHTTPTransport over loopback
        if let server = try PlatformPhase2Helper.LoopbackHTTPServer.start(handler: { reqText, write in
            if reqText.contains("GET /stream ") {
                let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                write(Array(head.utf8))
                let c1 = "chunk-a\n"
                write(Array("\(String(c1.utf8.count, radix: 16))\r\n\(c1)\r\n".utf8))
                PlatformPhase2Helper.sleepMs(15)
                let c2 = "chunk-b\n"
                write(Array("\(String(c2.utf8.count, radix: 16))\r\n\(c2)\r\n".utf8))
                write(Array("0\r\n\r\n".utf8))
            } else {
                let body = "hello-default-fetch"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                write(Array(resp.utf8))
            }
        }) {
            defer { server.stop() }

            let fetchOut = try await LayerNodePlatform.fetchLayer().build(LayerNode.Output(), scope)
            let defaultFetch = try #require(fetchOut.get(LayerNodePlatform.fetchKey, as: LayerNodePlatform.Fetch.self))
            let unaryResp = try await defaultFetch(
                HTTPRequest(method: "GET", url: "http://127.0.0.1:\(server.port)/ping")
            )
            #expect(unaryResp.head.statusCode == 200)
            #expect(String(decoding: unaryResp.body, as: UTF8.self) == "hello-default-fetch")

            // Streaming through default httpClient preserves real incremental streaming
            let streamResp = try await transport.stream(
                HTTPRequest(method: "GET", url: "http://127.0.0.1:\(server.port)/stream")
            )
            #expect(streamResp.head.statusCode == 200)
            var combined: [UInt8] = []
            for try await chunk in streamResp.chunks {
                combined.append(contentsOf: chunk)
            }
            #expect(String(decoding: combined, as: UTF8.self) == "chunk-a\nchunk-b\n")
        }
        #endif

        // Custom fetch override replaces httpFetch and wraps it in FetchTransport
        let customFetch: LayerNodePlatform.Fetch = { req in
            HTTPResponse(
                head: HTTPResponseHead(statusCode: 202, headers: ["x-custom": "yes"]),
                body: Array("intercepted:\(req.url)".utf8)
            )
        }
        let compiledOverride = try LayerNode.compile(
            LayerNodePlatform.httpClient,
            options: LayerNode.CompileOptions(
                replacements: [
                    LayerNodePlatform.httpFetch.replace(with: LayerNodePlatform.fetchLayer(customFetch)),
                ]
            )
        )
        let builtOverride = try await compiledOverride.build(scope: scope)
        let overrideTransport = try #require(
            builtOverride.get(LayerNodePlatform.httpClientKey, as: (any HTTPTransport).self)
        )
        #expect(overrideTransport is LayerNodePlatform.FetchTransport)
        let overrideResp = try await overrideTransport.send(
            HTTPRequest(method: "GET", url: "https://custom.invalid/test")
        )
        #expect(overrideResp.head.statusCode == 202)
        #expect(String(decoding: overrideResp.body, as: UTF8.self) == "intercepted:https://custom.invalid/test")
    }

    // MARK: - 2. Concurrent stdout+stderr Subprocess Pipes, Timeouts, Live Abort & Real RSS

    @Test("HostProcessSpawner drains >128KB stdout and >128KB stderr concurrently without deadlocking")
    func concurrentHeavyStdoutAndStderrDoesNotDeadlock() async throws {
        #if os(macOS) || os(Linux)
        // 160 KiB (> 128 KiB, exceeding 64 KiB OS pipe buffers) written simultaneously to stdout and stderr.
        let expectedBytes = 160 * 1024
        let script = """
        (dd if=/dev/zero bs=1024 count=160 2>/dev/null | tr '\\0' 'A') &
        (dd if=/dev/zero bs=1024 count=160 2>/dev/null | tr '\\0' 'B' 1>&2) &
        wait
        """
        let output = try await CrossSpawnSpawner.HostProcessSpawner.shared.run(
            ProcessSpec(executable: "/bin/sh", arguments: ["-c", script]),
            timeoutMs: 10_000,
            signal: nil
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout.count == expectedBytes)
        #expect(output.stderr.count == expectedBytes)
        #expect(output.stdout.first == UInt8(ascii: "A"))
        #expect(output.stdout.last == UInt8(ascii: "A"))
        #expect(output.stderr.first == UInt8(ascii: "B"))
        #expect(output.stderr.last == UInt8(ascii: "B"))
        #endif
    }

    @Test("AppProcess.Service.run terminates sleeping children on timeoutMs, live AbortSignal, and SIGTERM-ignoring children via SIGKILL")
    func appProcessTimeoutLiveAbortAndSigkillEscalation() async throws {
        #if os(macOS) || os(Linux)
        let service = AppProcess.Service(spawner: CrossSpawnSpawner.HostProcessSpawner.shared)

        // 1. timeoutMs kills a sleeping child promptly
        let t0 = RealPlatformFixesHelper.currentEpochMs()
        do {
            _ = try await service.run(
                ProcessSpec(executable: "/bin/sleep", arguments: ["30"]),
                options: AppProcess.RunOptions(timeoutMs: 120)
            )
            Issue.record("Expected timeout AppProcessError")
        } catch let err as AppProcess.AppProcessError {
            let elapsed = RealPlatformFixesHelper.currentEpochMs() - t0
            #expect(err.message.contains("Timed out"))
            #expect(elapsed < 5_000)
        }

        // 2. Live AbortSignal kills a running child mid-flight
        let controller = AbortController()
        let t1 = RealPlatformFixesHelper.currentEpochMs()
        let aborter = Task {
            try? await Task.sleep(for: .milliseconds(100))
            controller.abort(reason: AbortError(message: "caller-cancelled"))
        }
        do {
            _ = try await service.run(
                ProcessSpec(executable: "/bin/sleep", arguments: ["30"]),
                options: AppProcess.RunOptions(signal: controller.signal)
            )
            Issue.record("Expected abort AppProcessError")
        } catch let err as AppProcess.AppProcessError {
            let elapsed = RealPlatformFixesHelper.currentEpochMs() - t1
            #expect(err.message.contains("caller-cancelled") || err.message.contains("Abort"))
            #expect(elapsed < 5_000)
        }
        await aborter.value

        // 3. SIGTERM -> SIGKILL escalation kills a child that ignores SIGTERM
        let t2 = RealPlatformFixesHelper.currentEpochMs()
        do {
            _ = try await CrossSpawnSpawner.HostProcessSpawner.shared.run(
                ProcessSpec(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"]),
                timeoutMs: 100,
                signal: nil,
                forceKillAfterMs: 150
            )
            Issue.record("Expected SIGKILL escalated timeout error")
        } catch {
            let elapsed = RealPlatformFixesHelper.currentEpochMs() - t2
            #expect(elapsed < 5_000)
        }
        #endif
    }

    @Test("HeapSnapshot.write reports real positive process RSS memory bytes")
    func heapSnapshotReportsRealRSS() async throws {
        let fs = InMemoryFileSystem()
        let result = try await HeapSnapshot.write(directory: "/heap-snaps", fileSystem: fs)
        #if os(macOS) || os(Linux)
        #expect(result.pid > 0)
        #expect(result.memory.rss > 0)
        #endif

        let rawBytes = try await fs.readFile(at: result.path)
        let parsed = try RealPlatformFixesHelper.parseJSON(rawBytes)
        let memObj = try #require(RealPlatformFixesHelper.objectField(parsed, "memory"))
        let jsonRss = try #require(RealPlatformFixesHelper.numberValue(RealPlatformFixesHelper.objectField(memObj, "rss")))
        #expect(Int64(jsonRss) == result.memory.rss)
        #if os(macOS) || os(Linux)
        #expect(jsonRss > 0)
        #endif
    }

    // MARK: - 3. Real OTLP JSON Export over HTTPTransport

    @Test("Otlp.loggers defaults to URLSessionHTTPTransport and OtlpLogSink emits valid OTLP resourceLogs JSON")
    func otlpLogSinkDefaultTransportAndValidJSON() async throws {
        #if !os(WASI)
        let defaultSinks = Otlp.loggers(
            options: Otlp.Options(endpoint: "https://collector.example.test", headers: "Authorization=Bearer tok"),
            app: Otlp.App(client: "cli", version: "2.5.0", channel: "stable")
        )
        #expect(defaultSinks.count == 1)
        #expect(defaultSinks[0].transport is URLSessionHTTPTransport)
        #endif

        let mock = MockHTTPTransport()
        mock.enqueueResponse(statusCode: 200, headers: [:], text: "{}")

        let sinks = Otlp.loggers(
            options: Otlp.Options(endpoint: "https://collector.example.test", headers: "x-api-key=secret-42"),
            app: Otlp.App(client: "sdk", version: "3.1.4", channel: "prod"),
            transport: mock
        )
        #expect(sinks.count == 1)
        let sink = sinks[0]

        let record = StructuredLogRecord(
            timestamp: "2026-06-15T12:30:00.500Z",
            level: .warn,
            message: "cache miss on hot key",
            fields: [("component", "cache"), ("key", "sess_1")],
            cause: "evicted"
        )
        await sink.log(record)

        #expect(mock.recordedRequests.count == 1)
        let req = mock.recordedRequests[0]
        #expect(req.method == "POST")
        #expect(req.url == "https://collector.example.test/v1/logs")
        #expect(req.headers["Content-Type"] == "application/json")
        #expect(req.headers["x-api-key"] == "secret-42")

        let bodyBytes = try #require(req.body)
        let json = try RealPlatformFixesHelper.parseJSON(bodyBytes)

        // Validate OTLP ExportLogsServiceRequest structure: resourceLogs -> resource + scopeLogs -> logRecords
        let resourceLogs = try #require(
            RealPlatformFixesHelper.objectField(json, "resourceLogs").flatMap(RealPlatformFixesHelper.arrayElements)
        )
        #expect(resourceLogs.count == 1)
        let firstRL = resourceLogs[0]

        let resourceObj = try #require(RealPlatformFixesHelper.objectField(firstRL, "resource"))
        let resourceAttrs = try #require(
            RealPlatformFixesHelper.objectField(resourceObj, "attributes").flatMap(RealPlatformFixesHelper.arrayElements)
        )
        let resourceAttrMap: [String: String] = Dictionary(uniqueKeysWithValues: resourceAttrs.compactMap { entry in
            guard let k = RealPlatformFixesHelper.stringValue(RealPlatformFixesHelper.objectField(entry, "key")),
                  let valObj = RealPlatformFixesHelper.objectField(entry, "value"),
                  let v = RealPlatformFixesHelper.stringValue(RealPlatformFixesHelper.objectField(valObj, "stringValue")) else {
                return nil
            }
            return (k, v)
        })
        #expect(resourceAttrMap["service.name"] == "opencode")
        #expect(resourceAttrMap["service.version"] == "3.1.4")
        #expect(resourceAttrMap["opencode.client"] == "sdk")
        #expect(resourceAttrMap["deployment.environment.name"] == "prod")

        let scopeLogs = try #require(
            RealPlatformFixesHelper.objectField(firstRL, "scopeLogs").flatMap(RealPlatformFixesHelper.arrayElements)
        )
        #expect(scopeLogs.count == 1)
        let logRecords = try #require(
            RealPlatformFixesHelper.objectField(scopeLogs[0], "logRecords").flatMap(RealPlatformFixesHelper.arrayElements)
        )
        #expect(logRecords.count == 1)
        let logRec = logRecords[0]
        #expect(RealPlatformFixesHelper.stringValue(RealPlatformFixesHelper.objectField(logRec, "severityText")) == "WARN")
        #expect(RealPlatformFixesHelper.numberValue(RealPlatformFixesHelper.objectField(logRec, "severityNumber")) == 13)
        let bodyObj = try #require(RealPlatformFixesHelper.objectField(logRec, "body"))
        #expect(RealPlatformFixesHelper.stringValue(RealPlatformFixesHelper.objectField(bodyObj, "stringValue")) == "cache miss on hot key")
        let timeNanoStr = try #require(RealPlatformFixesHelper.stringValue(RealPlatformFixesHelper.objectField(logRec, "timeUnixNano")))
        #expect(UInt64(timeNanoStr) == 1_781_526_600_500_000_000)

        let logAttrs = try #require(
            RealPlatformFixesHelper.objectField(logRec, "attributes").flatMap(RealPlatformFixesHelper.arrayElements)
        )
        let logAttrMap: [String: String] = Dictionary(uniqueKeysWithValues: logAttrs.compactMap { entry in
            guard let k = RealPlatformFixesHelper.stringValue(RealPlatformFixesHelper.objectField(entry, "key")),
                  let valObj = RealPlatformFixesHelper.objectField(entry, "value"),
                  let v = RealPlatformFixesHelper.stringValue(RealPlatformFixesHelper.objectField(valObj, "stringValue")) else {
                return nil
            }
            return (k, v)
        })
        #expect(logAttrMap["component"] == "cache")
        #expect(logAttrMap["key"] == "sess_1")
        #expect(logAttrMap["cause"] == "evicted")
    }

    // MARK: - 4. NpmPlatform.Service Versioned Generation Installer

    @Test("NpmPlatform.Service.add and update invoke installer into versioned generation directories and clean up failures")
    func npmPlatformVersionedGenerationsAndInstaller() async throws {
        struct InstallCall: Equatable, Sendable {
            let pkg: String
            let dir: String
            let update: Bool
        }

        let fs = InMemoryFileSystem()
        let clock = Mutex<Int64>(10_000)
        let calls = Mutex<[InstallCall]>([])
        let shouldFail = Mutex<Bool>(false)

        let service = NpmPlatform.Service(
            cacheRoot: "/cache",
            fsUtil: FSUtil.Service(fileSystem: fs),
            installer: { pkg, genDir, isUpdate in
                calls.withLock { $0.append(InstallCall(pkg: pkg, dir: genDir, update: isUpdate)) }
                if shouldFail.withLock({ $0 }) {
                    throw PlatformError.ioFailure("registry unreachable")
                }
                let ver = isUpdate ? "1.1.0" : "1.0.0"
                try await fs.writeFile(
                    Array("{\"name\":\"@acme/cli\",\"version\":\"\(ver)\"}".utf8),
                    to: "\(genDir)/node_modules/@acme/cli/package.json",
                    createDirectories: true
                )
                try await fs.writeFile(
                    Array("#!/bin/sh\necho ok\n".utf8),
                    to: "\(genDir)/node_modules/.bin/cli",
                    createDirectories: true
                )
            },
            nowMs: { clock.withLock { $0 } }
        )

        // First add installs into generation 10000
        let first = try await service.add("@acme/cli@latest")
        #expect(first.name == "@acme/cli")
        #expect(first.directory == "/cache/npm/@acme/cli@latest/10000")
        #expect(first.version == "1.0.0")
        #expect(await service.which("@acme/cli@latest") == "/cache/npm/@acme/cli@latest/10000/node_modules/.bin/cli")
        #expect(calls.withLock { $0 } == [
            InstallCall(pkg: "@acme/cli@latest", dir: "/cache/npm/@acme/cli@latest/10000", update: false),
        ])

        // Second add hits existing generation cache without re-running installer
        clock.withLock { $0 = 15_000 }
        let cached = try await service.add("@acme/cli@latest")
        #expect(cached.directory == "/cache/npm/@acme/cli@latest/10000")
        #expect(calls.withLock { $0.count } == 1)

        // update() installs into a newer generation directory (15000) with update == true
        let updated = try await service.update("@acme/cli@latest")
        #expect(updated.directory == "/cache/npm/@acme/cli@latest/15000")
        #expect(updated.version == "1.1.0")
        #expect(calls.withLock { $0.count } == 2)
        #expect(calls.withLock { $0.last } == InstallCall(pkg: "@acme/cli@latest", dir: "/cache/npm/@acme/cli@latest/15000", update: true))

        // Failed update cleans up broken generation directory and leaves previous generation active
        clock.withLock { $0 = 20_000 }
        shouldFail.withLock { $0 = true }
        await #expect(throws: NpmSpec.InstallFailedError.self) {
            _ = try await service.update("@acme/cli@latest")
        }
        #expect(!(await fs.exists(at: "/cache/npm/@acme/cli@latest/20000")))
        let stillActive = await service.resolve("@acme/cli@latest")
        #expect(stillActive.directory == "/cache/npm/@acme/cli@latest/15000")

        // reject() only applies to the newest generation when its version matches and a previous one exists
        #expect(try await service.reject("@acme/cli@latest", version: "1.0.0") == false)
        #expect(try await service.reject("@acme/cli@latest", version: "1.1.0") == true)
        #expect(await fs.exists(at: "/cache/npm/@acme/cli@latest/15000.rejected"))
        #expect(await fs.exists(at: "/cache/npm/@acme/cli@latest/15000"))
        let rolledBack = await service.resolve("@acme/cli@latest")
        #expect(rolledBack.directory == "/cache/npm/@acme/cli@latest/10000")
        #expect(rolledBack.version == "1.0.0")
        // Only one completed generation remains, so nothing more can be rejected
        #expect(try await service.reject("@acme/cli@latest", version: "1.0.0") == false)
    }

    @Test("NpmPlatform.defaultProcessInstaller tries bun add and falls back to npm install --prefix")
    func npmPlatformDefaultProcessInstallerFallback() async throws {
        #if os(macOS) || os(Linux) || os(Windows)
        let fs = InMemoryFileSystem()
        let spawned = Mutex<[ProcessSpec]>([])
        let mockSpawner = RecordingProcessSpawner { spec in
            spawned.withLock { $0.append(spec) }
            if spec.executable == "bun" {
                return ProcessOutput(exitCode: 127, stdout: [], stderr: Array("bun: not found".utf8))
            }
            return ProcessOutput(exitCode: 0, stdout: Array("added 1 package".utf8), stderr: [])
        }

        let installer = NpmPlatform.defaultProcessInstaller(
            spawner: mockSpawner,
            fileSystem: fs,
            environment: DictionaryEnvironment(variables: ["NPM_CONFIG_REGISTRY": "https://mirror.example.test/"])
        )
        try await installer("left-pad@1.3.0", "/tmp/gen-1", true)

        let cmds = spawned.withLock { $0 }
        #expect(cmds.count == 2)
        #expect(cmds[0].executable == "bun")
        #expect(cmds[0].arguments.contains("add"))
        #expect(cmds[0].arguments.contains("left-pad@1.3.0"))
        #expect(cmds[0].arguments.contains("https://mirror.example.test"))

        #expect(cmds[1].executable == "npm")
        #expect(cmds[1].arguments.contains("install"))
        #expect(cmds[1].arguments.contains("--prefix"))
        #expect(cmds[1].arguments.contains("/tmp/gen-1"))
        #expect(cmds[1].arguments.contains("--prefer-online"))
        #expect(cmds[1].arguments.contains("left-pad@1.3.0"))
        #expect(await fs.exists(at: "/tmp/gen-1/package.json"))
        #endif
    }
}

// MARK: - Serialized Suite for Live OS POSIX Signal Delivery

// Lives in the serialized `ProcessSignalTests` suite: both tests reset the process-global signal registry,
// so they must never run concurrently.
extension ProcessSignalTests {
    @Test("ProcessSignal.install dispatches real OS SIGUSR1 signal to registered Swift subscriber")
    func realPosixSIGUSR1DispatchesToSubscriber() async throws {
        #if os(macOS) || os(Linux)
        ProcessSignal.reset()
        defer { ProcessSignal.reset() }

        let received = Mutex<Int>(0)
        ProcessSignal.install(signal: "SIGUSR1") {
            // unavailable fallback
        }
        let unsubscribe = ProcessSignal.subscribe(signal: "SIGUSR1") {
            received.withLock { $0 += 1 }
        }
        defer { unsubscribe() }

        let sent = RealPlatformFixesHelper.sendSIGUSR1ToSelf()
        #expect(sent)

        // Wait up to 2s for the self-pipe reader thread to deliver SIGUSR1
        var delivered = false
        for _ in 0..<200 {
            if received.withLock({ $0 }) >= 1 {
                delivered = true
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(delivered)
        #expect(received.withLock { $0 } >= 1)
        #endif
    }
}

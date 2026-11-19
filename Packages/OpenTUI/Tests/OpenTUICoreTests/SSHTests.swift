import OpenTUICore
import OpenTUITerminal
import Synchronization
import Testing

private struct TestFailure: Error, Equatable, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private struct UserContextKey: SSHContextKey {
    typealias Value = String
}

private struct RoleContextKey: SSHContextKey {
    typealias Value = [String]
}

// MARK: - Helpers

private func waitUntil(
    timeoutMs: Int = 2_000,
    pollMs: Int = 5,
    _ condition: @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .milliseconds(timeoutMs))
    while !condition() {
        if clock.now >= deadline {
            return false
        }
        try? await Task.sleep(for: .milliseconds(pollMs))
    }
    return true
}

private func hexString(_ bytes: [UInt8]) -> String {
    let digits: [UInt8] = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    for b in bytes {
        out.append(digits[Int(b >> 4)])
        out.append(digits[Int(b & 0x0F)])
    }
    return String(decoding: out, as: UTF8.self)
}

// MARK: - Errors & Safe Utilities

@Suite("SSH Errors & Safe")
struct SSHErrorsAndSafeTests {
    @Test("Error codes, names, prefixes, and isDeny")
    func errorVocabulary() {
        let base = SshError(code: "CUSTOM", message: "boom")
        #expect(base.code == "CUSTOM")
        #expect(base.name == "SshError")
        #expect(base.message == "@opentui/ssh: boom")
        #expect(!isDeny(base))

        let cfg = ConfigError("bad config")
        #expect(cfg.code == "CONFIG")
        #expect(cfg.name == "ConfigError")
        #expect(cfg.message == "@opentui/ssh: bad config")
        #expect(!isDeny(cfg))

        let pressure = OutputPressureError()
        #expect(pressure.code == "OUTPUT_PRESSURE")
        #expect(pressure.name == "OutputPressureError")
        #expect(pressure.message == "@opentui/ssh: native session output is full; no bytes were accepted")

        let cap = SSHOutputCapacityError()
        #expect(cap.code == "RANGE")
        #expect(cap.name == "RangeError")

        let denyWithReason = DenyError("quota exceeded")
        #expect(denyWithReason.reason == "quota exceeded")
        #expect(denyWithReason.message == "quota exceeded")
        #expect(denyWithReason.description == "quota exceeded")
        #expect(isDeny(denyWithReason))

        let denyPlain = DenyError()
        #expect(denyPlain.reason == nil)
        #expect(denyPlain.message == "session denied")
        #expect(isDeny(denyPlain))
    }

    @Test("createSafeInvoke contains sync/async throws and throwing sinks without starving siblings")
    func safeInvokeIsolation() async {
        let seen = Mutex<[String]>([])
        let safe = createSafeInvoke { err in
            seen.withLock { $0.append(String(describing: err)) }
            throw TestFailure(message: "sink-boom")
        }

        let siblingReached = Mutex(false)
        safe { throw TestFailure(message: "sync-boom") }
        safe { siblingReached.withLock { $0 = true } }
        await safe {
            await Task.yield()
            throw TestFailure(message: "async-boom")
        }
        safe.report(TestFailure(message: "direct-boom"))

        #expect(siblingReached.withLock { $0 } == true)
        #expect(seen.withLock { $0 } == ["sync-boom", "async-boom", "direct-boom"])
    }

    @Test("ignoreErrors swallows sync and async failures")
    func ignoreErrorsSwallows() async {
        ignoreErrors { throw TestFailure(message: "ignored") }
        await ignoreErrors {
            await Task.yield()
            throw TestFailure(message: "ignored-async")
        }
    }

    @Test("timingSafeEqual compares bytes and strings accurately")
    func timingSafeComparison() {
        #expect(timingSafeEqual([1, 2, 3], [1, 2, 3]))
        #expect(!timingSafeEqual([1, 2, 3], [1, 2, 4]))
        #expect(!timingSafeEqual([1, 2, 3], [1, 2]))
        #expect(timingSafeEqual([], []))
        #expect(timingSafeEqual("hunter2", "hunter2"))
        #expect(!timingSafeEqual("hunter2", "hunter3"))
        #expect(!timingSafeEqual("hunter2", "hunter"))
    }

    @Test("escapeControlCharacters escapes C0, DEL, and C1 scalars")
    func controlEscaping() {
        let raw = "alice\u{0000}\r\nFORGED\u{001B}[2J\u{007F}\u{0085}✓"
        let escaped = escapeControlCharacters(raw)
        #expect(escaped == "alice\\u0000\\u000d\\u000aFORGED\\u001b[2J\\u007f\\u0085✓")
    }
}

// MARK: - Keys, SHA-256, Base64 & Banner

@Suite("SSH Keys & Banner")
struct SSHKeysAndBannerTests {
    @Test("Pure-Swift SHA-256 matches FIPS 180-4 NIST test vectors")
    func sha256Vectors() {
        #expect(
            hexString(SSHSHA256.hash([]))
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        #expect(
            hexString(SSHSHA256.hash(Array("abc".utf8)))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        #expect(
            hexString(SSHSHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    @Test("Pure-Swift Base64 encodes, decodes, and rejects invalid input")
    func base64RoundTrip() {
        let samples: [[UInt8]] = [[], [0], [1, 2], [1, 2, 3], Array("hello world!".utf8)]
        for bytes in samples {
            let padded = SSHBase64.encode(bytes, padding: true)
            let unpadded = SSHBase64.encode(bytes, padding: false)
            #expect(SSHBase64.decode(padded) == bytes)
            #expect(SSHBase64.decode(unpadded) == bytes)
        }
        #expect(SSHBase64.decode("not!base64") == nil)
        #expect(SSHBase64.decode("A") == nil) // invalid length % 4 == 1
        #expect(SSHBase64.decode("AB==") == nil) // non-zero trailing unused bits
    }

    @Test("OpenSSH authorized_keys parser supports comments, options with quotes, and validates blobs")
    func authorizedKeysParsing() throws {
        let key1 = generateEd25519KeyPair(comment: "alice@host")
        let key2 = generateEd25519KeyPair()

        let doc = """
        # Comment line

        \(key1.publicLine)
        from="10.0.0.1,10.0.0.2",command="/bin/echo \\"hi\\"",no-port-forwarding \(key2.parsed.type) \(key2.parsed.publicSSHBase64) bob@work
        """

        let parsed = try parseAuthorizedKeys(doc)
        #expect(parsed.count == 2)
        #expect(parsed[0].type == "ssh-ed25519")
        #expect(parsed[0].comment == "alice@host")
        #expect(parsed[0].fingerprint == key1.parsed.fingerprint)
        #expect(parsed[0].fingerprint.hasPrefix("SHA256:"))
        #expect(!parsed[0].fingerprint.hasSuffix("="))

        #expect(parsed[1].type == "ssh-ed25519")
        #expect(parsed[1].comment == "bob@work")
        #expect(parsed[1].options.count == 3)
        #expect(parsed[1].options[0] == "from=\"10.0.0.1,10.0.0.2\"")
        #expect(parsed[1].options[2] == "no-port-forwarding")

        // Normalize fingerprint strips trailing '=' padding.
        let normalized = normalizeFingerprint("\(parsed[0].fingerprint)=")
        #expect(normalized == parsed[0].fingerprint)
        #expect(normalizeFingerprint("MD5:aa:bb") == nil)
        #expect(normalizeFingerprint("SHA256:short") == nil)

        // Malformed lines fail cleanly.
        #expect(parseAuthorizedKeyLine("ssh-ed25519 not-valid-base64!") == nil)
        #expect(parseAuthorizedKeyLine("ssh-rsa \(key1.parsed.publicSSHBase64)") == nil) // mismatched wire type
        #expect(throws: ConfigError.self) {
            _ = try parseAuthorizedKeys("not a valid key line\n")
        }
    }

    @Test("resolveHostKey handles ephemeral, provided PEMs, and persisted path via InMemorySSHKeyFileStore")
    func hostKeyResolution() throws {
        let eph1 = try resolveHostKey(nil)
        let eph2 = try resolveHostKey(nil)
        #expect(eph1.source == "ephemeral")
        #expect(eph1.algorithms == ["ssh-ed25519"])
        #expect(eph1.fingerprints[0].hasPrefix("SHA256:"))
        #expect(eph1.fingerprints[0] != eph2.fingerprints[0])

        let pair = generateEd25519KeyPair()
        let provided = try resolveHostKey(.pem(pair.privatePem))
        #expect(provided.source == "provided")
        #expect(provided.fingerprints == [pair.parsed.fingerprint])

        #expect(throws: ConfigError.self) {
            _ = try resolveHostKey(.pem([]))
        }
        #expect(throws: ConfigError.self) {
            _ = try resolveHostKey(.pem([pair.privatePem, "not a key"]))
        }
        #expect(throws: ConfigError.self) {
            _ = try resolveHostKey(.path(""))
        }

        let store = InMemorySSHKeyFileStore()
        let first = try resolveHostKey(.path("/var/lib/opentui/host_ed25519"), fileStore: store)
        #expect(first.source == "generated /var/lib/opentui/host_ed25519")
        let second = try resolveHostKey(.path("/var/lib/opentui/host_ed25519"), fileStore: store)
        #expect(second.source == "loaded /var/lib/opentui/host_ed25519")
        #expect(second.fingerprints == first.fingerprints)
    }

    @Test("formatBanner and normalizeBanner match upstream formatting and sanitization")
    func bannerFormattingAndNormalization() {
        let k1 = generateEd25519KeyPair().parsed
        let k2 = generateEd25519KeyPair().parsed
        let k3 = generateEd25519KeyPair().parsed
        let k4 = generateEd25519KeyPair().parsed

        let infoV6 = SSHListenInfo(host: "::1", port: 2222, fingerprints: [k1.fingerprint])
        let desc = SSHBannerDescriptor(
            algorithms: ["ssh-ed25519"],
            source: "provided",
            methods: ["publickey", "password"],
            authorizedKeys: [k1.publicSSHBase64, k2.publicSSHBase64, k3.publicSSHBase64, k4.publicSSHBase64]
        )
        let lines = formatBanner(info: infoV6, descriptor: desc)
        #expect(lines[0] == "@opentui/ssh  ▸  ssh://[::1]:2222")
        #expect(lines[1].contains(k1.fingerprint))
        #expect(lines[1].contains("(ssh-ed25519, provided)"))
        #expect(lines[2] == "auth          publickey, password")
        #expect(lines[3].contains("4 keys"))
        #expect(lines[3].hasSuffix(" …"))

        let wildcard = formatBanner(
            info: SSHListenInfo(host: "0.0.0.0", port: 2200, fingerprints: [k1.fingerprint]),
            descriptor: SSHBannerDescriptor(algorithms: ["ssh-ed25519"], source: "ephemeral", methods: ["none"])
        )
        #expect(wildcard[0] == "@opentui/ssh  ▸  ssh://localhost:2200")
        #expect(wildcard.count == 3)

        #expect(normalizeBanner(nil) == nil)
        #expect(normalizeBanner("   \t\r\n  ") == nil)
        #expect(normalizeBanner("Welcome\nLine 2\rLine 3\r\n") == "Welcome\r\nLine 2\r\nLine 3\r\n")
        #expect(normalizeBanner("Hi\u{001B}[31m!\u{0007}\u{009B}end") == "Hi[31m!end\r\n")
    }
}

// MARK: - Auth Core & Policy Resolution

@Suite("SSH Authentication")
struct SSHAuthTests {
    @Test("attemptFromAuthContext adapts all supported methods and maps unmodeled methods to nil")
    func authContextAdaptation() async {
        let noneAttempt = attemptFromAuthContext(SSHRawAuthContext(method: "none", username: "guest"))
        if case .some(.none(let u)) = noneAttempt {
            #expect(u == "guest")
        } else {
            Issue.record("expected none attempt")
        }

        let pwAttempt = attemptFromAuthContext(SSHRawAuthContext(method: "password", username: "erin", password: "pw"))
        if case .password(let u, let p) = pwAttempt {
            #expect(u == "erin")
            #expect(p == "pw")
        } else {
            Issue.record("expected password attempt")
        }

        let kbiAttempt = attemptFromAuthContext(SSHRawAuthContext(
            method: "keyboard-interactive",
            username: "frank",
            prompt: { _, cb in cb(nil) }
        ))
        if case .keyboardInteractive(let u, let prompt) = kbiAttempt {
            #expect(u == "frank")
            let answers = await prompt([SSHKeyboardQuestion(prompt: "Code: ", echo: false)])
            #expect(answers == [])
        } else {
            Issue.record("expected keyboard-interactive attempt")
        }

        let pkProbe = attemptFromAuthContext(SSHRawAuthContext(
            method: "publickey",
            username: "alice",
            keyAlgorithm: "ssh-ed25519",
            keyData: [1, 2, 3]
        ))
        if case .publicKey(let u, let key, let sig, let blob, let hashAlgo) = pkProbe {
            #expect(u == "alice")
            #expect(key == SSHPublicKey(algorithm: "ssh-ed25519", blob: [1, 2, 3]))
            #expect(sig == nil)
            #expect(blob == nil)
            #expect(hashAlgo == nil)
        } else {
            Issue.record("expected publickey probe attempt")
        }

        #expect(attemptFromAuthContext(SSHRawAuthContext(method: "hostbased", username: "mallory")) == nil)
    }

    @Test("Authenticator enforces none, password, keyboard-interactive, and fail-closed predicate throws")
    func authenticatorBasicMethods() async {
        let openAuth = createAuthenticator(auth: SSHNormalizedAuthConfig(none: true))
        #expect(openAuth.advertisedMethods() == [.none])
        #expect(await openAuth.authenticate(.none(username: "guest")) == .accept(identity: .none(username: "guest")))
        #expect(await openAuth.authenticate(.password(username: "guest", password: "x")) == .reject(methods: [.none]))

        let errors = Mutex<[String]>([])
        let pwAuth = createAuthenticator(
            auth: SSHNormalizedAuthConfig(
                password: { ctx in
                    if ctx.username == "boom" { throw TestFailure(message: "backend down") }
                    return timingSafeEqual(ctx.password, "hunter2")
                },
                keyboardInteractive: { ctx in
                    let answers = await ctx.prompt([SSHKeyboardQuestion(prompt: "OTP: ", echo: false)])
                    return answers.first == "123456"
                }
            ),
            onError: { err in errors.withLock { $0.append(String(describing: err)) } }
        )
        #expect(pwAuth.advertisedMethods() == [.password, .keyboardInteractive])
        #expect(await pwAuth.authenticate(.password(username: "erin", password: "hunter2")) == .accept(identity: .password(username: "erin")))
        #expect(await pwAuth.authenticate(.password(username: "erin", password: "wrong")) == .reject(methods: [.password, .keyboardInteractive]))
        #expect(await pwAuth.authenticate(.password(username: "boom", password: "x")) == .reject(methods: [.password, .keyboardInteractive]))
        #expect(errors.withLock { $0 } == ["backend down"])

        let kbiOK = await pwAuth.authenticate(.keyboardInteractive(username: "frank", prompt: { _ in ["123456"] }))
        #expect(kbiOK == .accept(identity: .keyboardInteractive(username: "frank")))
        let kbiBad = await pwAuth.authenticate(.keyboardInteractive(username: "frank", prompt: { _ in ["000000"] }))
        #expect(kbiBad == .reject(methods: [.password, .keyboardInteractive]))
    }

    @Test("Public-key probe vs signed verification, forged signature rejection, and allowlist + allow OR-merge")
    func publicKeyAuthAndSignatures() async {
        let listed = generateEd25519KeyPair().parsed
        let dynamicKey = generateEd25519KeyPair().parsed
        let stranger = generateEd25519KeyPair().parsed
        let blob = Array("ssh-session-id-blob".utf8)

        // Use real Ed25519 signatures when CryptoKit is available, else deterministic verifier.
        let useRealCrypto = listed.sign(blob: blob) != nil
        let verifier: any SSHSignatureVerifier = useRealCrypto
            ? DefaultSSHSignatureVerifier()
            : ClosureSSHSignatureVerifier { key, msg, sig, _ in
                timingSafeEqual(sig, SSHSHA256.hash(key.blob + msg))
            }

        func sign(_ key: SSHParsedKey, over data: [UInt8]) -> [UInt8] {
            if let realSig = key.sign(blob: data) {
                return realSig
            }
            return SSHSHA256.hash(key.publicSSH + data)
        }

        let allowInvocations = Mutex(0)
        let dynamicFp = dynamicKey.fingerprint

        let auth = createAuthenticator(
            auth: SSHNormalizedAuthConfig(
                publicKey: .policy(SSHPublicKeyPolicy(
                    allow: { ctx in
                        allowInvocations.withLock { $0 += 1 }
                        return ctx.fingerprint == dynamicFp
                    }
                ))
            ),
            authorizedKeys: [listed.publicSSHBase64],
            signatureVerifier: verifier
        )

        #expect(auth.advertisedMethods() == [.publicKey])

        // Probe must return .acceptProbe and NEVER invoke `allow`.
        let probe = await auth.authenticate(.publicKey(
            username: "alice",
            key: SSHPublicKey(algorithm: dynamicKey.type, blob: dynamicKey.publicSSH)
        ))
        #expect(probe == .acceptProbe)
        #expect(allowInvocations.withLock { $0 } == 0)

        // Forged signature must fail closed without invoking `allow`.
        let forged = await auth.authenticate(.publicKey(
            username: "alice",
            key: SSHPublicKey(algorithm: listed.type, blob: listed.publicSSH),
            signature: [UInt8](repeating: 0x07, count: 64),
            blob: blob
        ))
        #expect(forged == .reject(methods: [.publicKey]))

        // Signature from WRONG private key must fail closed.
        let spoofed = await auth.authenticate(.publicKey(
            username: "alice",
            key: SSHPublicKey(algorithm: listed.type, blob: listed.publicSSH),
            signature: sign(stranger, over: blob),
            blob: blob
        ))
        #expect(spoofed == .reject(methods: [.publicKey]))

        // Listed key admitted via static allowlist (allow not even needed).
        let listedOK = await auth.authenticate(.publicKey(
            username: "alice",
            key: SSHPublicKey(algorithm: listed.type, blob: listed.publicSSH),
            signature: sign(listed, over: blob),
            blob: blob
        ))
        #expect(listedOK == .accept(identity: .publicKey(
            username: "alice",
            fingerprint: listed.fingerprint,
            publicKey: SSHPublicKey(algorithm: listed.type, blob: listed.publicSSH)
        )))

        // Dynamic key admitted via `allow` after signature verification.
        let dynamicOK = await auth.authenticate(.publicKey(
            username: "bob",
            key: SSHPublicKey(algorithm: dynamicKey.type, blob: dynamicKey.publicSSH),
            signature: sign(dynamicKey, over: blob),
            blob: blob
        ))
        #expect(dynamicOK == .accept(identity: .publicKey(
            username: "bob",
            fingerprint: dynamicKey.fingerprint,
            publicKey: SSHPublicKey(algorithm: dynamicKey.type, blob: dynamicKey.publicSSH)
        )))
        #expect(allowInvocations.withLock { $0 } == 1)

        // Stranger signed with own key is still rejected by both allowlist and allow.
        let strangerDenied = await auth.authenticate(.publicKey(
            username: "eve",
            key: SSHPublicKey(algorithm: stranger.type, blob: stranger.publicSSH),
            signature: sign(stranger, over: blob),
            blob: blob
        ))
        #expect(strangerDenied == .reject(methods: [.publicKey]))
    }

    @Test("resolveAuth validates open default, empty credentials, and authorizedKeys files")
    func authResolution() throws {
        let open = try resolveAuth(nil, onError: { _ in })
        #expect(open.noneOnly == true)
        #expect(open.authenticator.advertisedMethods() == [.none])

        #expect(throws: ConfigError.self) {
            _ = try resolveAuth(.methods(SSHAuthMethods()), onError: { _ in })
        }
        #expect(throws: ConfigError.self) {
            _ = try resolveAuth(.methods(SSHAuthMethods(publicKey: .policy(SSHPublicKeyPolicy()))), onError: { _ in })
        }

        let key = generateEd25519KeyPair().parsed
        let store = InMemorySSHKeyFileStore(textFiles: [
            "/etc/auth/good": "# comment\n\(key.authorizedKeyLine)\n",
            "/etc/auth/empty": "# only comments\n\n",
            "/etc/auth/bad": "garbage\n",
        ])

        let resolved = try resolveAuth(
            .methods(SSHAuthMethods(publicKey: .policy(SSHPublicKeyPolicy(authorizedKeys: .file("/etc/auth/good"))))),
            fileStore: store,
            onError: { _ in }
        )
        #expect(resolved.noneOnly == false)
        #expect(resolved.authorizedKeys == [key.publicSSHBase64])

        #expect(throws: ConfigError.self) {
            _ = try resolveAuth(
                .methods(SSHAuthMethods(publicKey: .policy(SSHPublicKeyPolicy(authorizedKeys: .file("/etc/auth/empty"))))),
                fileStore: store,
                onError: { _ in }
            )
        }
        #expect(throws: ConfigError.self) {
            _ = try resolveAuth(
                .methods(SSHAuthMethods(publicKey: .policy(SSHPublicKeyPolicy(authorizedKeys: .file("/etc/auth/bad"))))),
                fileStore: store,
                onError: { _ in }
            )
        }
        #expect(throws: ConfigError.self) {
            _ = try resolveAuth(
                .methods(SSHAuthMethods(publicKey: .policy(SSHPublicKeyPolicy(authorizedKeys: .file("/etc/auth/missing"))))),
                fileStore: store,
                onError: { _ in }
            )
        }
    }
}

// MARK: - Logging Middleware

@Suite("SSH Logging")
struct SSHLoggingTests {
    @Test("Default logging escapes control characters and emits connect + disconnect")
    func loggingControlEscaping() async {
        let lines = Mutex<[String]>([])
        let channel = InMemorySSHChannel()
        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(
                pty: SSHPtyInfo(term: "xterm\u{001B}]0;owned\u{0007}", cols: 80, rows: 24, hasPty: true),
                identity: .none(username: "alice\u{0000}\r\nFORGED\u{001B}[2J\u{007F}\u{0085}"),
                remoteAddress: SSHRemoteAddress(address: "127.0.0.1", port: 22)
            )
        )

        let task = runSession(
            middlewares: [
                sshLogging(options: SSHLoggingOptions(lineSink: { line in
                    lines.withLock { $0.append(line) }
                })),
            ],
            handler: { session in
                session.end()
            },
            bridge: bridge,
            safe: createSafeInvoke { _ in }
        )
        await task.value
        await bridge.destroy()

        let captured = lines.withLock { $0 }
        #expect(captured.count == 2)
        #expect(captured[0].contains("alice\\u0000\\u000d\\u000aFORGED\\u001b[2J\\u007f\\u0085@127.0.0.1:22"))
        #expect(captured[0].contains("xterm\\u001b]0;owned\\u0007 80×24"))
        #expect(captured[1].hasPrefix("disconnect "))
        for line in captured {
            for scalar in line.unicodeScalars {
                #expect(scalar.value > 0x1F)
                #expect(!(scalar.value >= 0x7F && scalar.value <= 0x9F))
            }
        }
    }

    @Test("Throwing async logging sink is isolated and never disrupts session execution")
    func loggingSinkIsolation() async {
        let handlerRan = Mutex(false)
        let channel = InMemorySSHChannel()
        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(identity: .none(username: "alice"))
        )

        let task = runSession(
            middlewares: [
                sshLogging(options: SSHLoggingOptions(log: { _ in
                    throw TestFailure(message: "sink crashed")
                })),
            ],
            handler: { session in
                handlerRan.withLock { $0 = true }
                session.end()
            },
            bridge: bridge,
            safe: createSafeInvoke { _ in }
        )
        await task.value
        await bridge.destroy()

        #expect(handlerRan.withLock { $0 } == true)
    }
}

// MARK: - Bridge, Backpressure & TerminalBackend

@Suite("SSH Bridge & TerminalBackend")
struct SSHBridgeTests {
    @Test("Output capacity limit and queue backpressure reject atomically without partial writes")
    func outputBackpressureAndCapacity() async throws {
        let channel = InMemorySSHChannel()
        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(
                identity: .none(username: "native"),
                maxOutputBufferBytes: 128
            )
        )

        // Single write exceeding max capacity throws SSHOutputCapacityError and writes 0 bytes.
        #expect(throws: SSHOutputCapacityError.self) {
            try bridge.session.write(String(repeating: "x", count: 129))
        }
        #expect(channel.writes.isEmpty)

        // Hold channel so output queues up to capacity (128 bytes), then rejects atomically.
        channel.hold()
        let chunk = [UInt8](repeating: 0x61, count: 64)
        try bridge.session.write(chunk) // 64 bytes in-flight
        try bridge.session.write(chunk) // 64 bytes queued -> total 128 bytes

        var pressureError: OutputPressureError? = nil
        do {
            try bridge.session.write([0x62])
        } catch let err as OutputPressureError {
            pressureError = err
        }
        #expect(pressureError?.code == "OUTPUT_PRESSURE")

        // Release channel: all 128 accepted bytes flush cleanly, and the rejected byte was never queued.
        channel.release()
        await bridge.destroy()
        #expect(channel.writtenBytes.count == 128)
        #expect(channel.writtenBytes.allSatisfy { $0 == 0x61 })
        #expect(channel.exits == [0])
    }

    @Test("deny writes CRLF reason, preserves existing line endings, and closes even on oversized reason")
    func denyFormattingAndTeardown() async {
        // 1. Plain reason appends CRLF
        do {
            let channel = InMemorySSHChannel()
            let bridge = createSessionBridge(
                channel: channel,
                options: SSHSessionBridgeOptions(identity: .none(username: "u"))
            )
            #expect(throws: DenyError("go away")) {
                try bridge.session.deny("go away")
            }
            await bridge.destroy()
            #expect(channel.writtenText == "go away\r\n")
            #expect(channel.exits == [0])
        }

        // 2. Existing newline preserved
        do {
            let channel = InMemorySSHChannel()
            let bridge = createSessionBridge(
                channel: channel,
                options: SSHSessionBridgeOptions(identity: .none(username: "u"))
            )
            #expect(throws: DenyError("bye\n")) {
                try bridge.session.deny("bye\n")
            }
            await bridge.destroy()
            #expect(channel.writtenText == "bye\n")
        }

        // 3. Oversized deny reason reports capacity error and still closes + throws DenyError
        do {
            let channel = InMemorySSHChannel()
            let reported = Mutex<[String]>([])
            let bridge = createSessionBridge(
                channel: channel,
                options: SSHSessionBridgeOptions(
                    identity: .none(username: "u"),
                    safe: createSafeInvoke { err in reported.withLock { $0.append(String(describing: err)) } },
                    maxOutputBufferBytes: 16
                )
            )
            #expect(throws: DenyError.self) {
                try bridge.session.deny(String(repeating: "x", count: 32))
            }
            await bridge.destroy()
            #expect(channel.writtenText == "")
            #expect(reported.withLock { $0.count } == 1)
        }
    }

    @Test("PTY clamping, pre-attach resize, stdin backpressure, and StdinParser integration")
    func ptyClampingStdinAndTerminalBackend() async throws {
        let channel = InMemorySSHChannel()
        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(
                pty: SSHPtyInfo(term: "", cols: 999_999, rows: -5, hasPty: true),
                env: ["COLORTERM": "truecolor"],
                identity: .none(username: "u"),
                stdinHighWaterMark: 4
            )
        )

        #expect(bridge.session.term == "xterm-256color")
        #expect(bridge.session.cols == sshMaxPty.cols)
        #expect(bridge.session.rows == Int(sshDefaultPty.rows))
        #expect(bridge.environment["TERM"] == "xterm-256color")
        #expect(bridge.environment["COLORTERM"] == "truecolor")

        // Pre-attach resize updates creation dimensions
        bridge.resize(cols: 120, rows: 40)
        #expect(bridge.session.cols == 120)
        #expect(bridge.session.rows == 40)

        // Pre-attach stdin triggers channel pause at high-water mark
        channel.receiveText("hello")
        #expect(channel.pauseCalls == 1)

        let parsedKeys = Mutex<[String]>([])
        let resizedTo = Mutex<[(Int, Int)]>([])
        _ = bridge.session.onResize { c, r in
            resizedTo.withLock { $0.append((c, r)) }
        }

        let task = runSession(
            middlewares: [],
            handler: { session in
                // Drive TerminalBackend directly over the SSH channel!
                let backend = session.terminalBackend
                #expect(await backend.size == TerminalSize(width: 120, height: 40))
                try await backend.enterRawMode()
                #expect(await backend.isRawMode == true)
                try await backend.write(Array("FRAME1".utf8))
                try await backend.exitRawMode()
                #expect(await backend.isRawMode == false)

                if let headless = session.renderer as? SSHHeadlessRenderer {
                    _ = headless.onStdinEvent { event in
                        if case .key(_, let key) = event {
                            parsedKeys.withLock { $0.append(key.name) }
                        }
                    }
                    #expect(String(decoding: headless.receivedInputBytes, as: UTF8.self) == "hello")
                }

                channel.receiveText("a")
                bridge.resize(cols: 100, rows: 30)
                session.end()
            },
            bridge: bridge,
            safe: createSafeInvoke { _ in }
        )

        await task.value
        await bridge.destroy()

        #expect(channel.resumeCalls >= 1)
        #expect(channel.writtenText == "FRAME1")
        #expect(parsedKeys.withLock { $0 } == ["a"])
        #expect(resizedTo.withLock { $0 }.contains { $0 == (100, 30) })
    }

    @Test("Disconnect during renderer setup destroys late renderer, skips handler, and reports no error")
    func midSetupDisconnectRace() async {
        let channel = InMemorySSHChannel()
        let errors = Mutex<[String]>([])
        let handlerRan = Mutex(false)
        let factoryStarted = Mutex(false)
        let releaseFactory = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let lateRendererBox = Mutex<SSHHeadlessRenderer?>(nil)

        let safe = createSafeInvoke { err in errors.withLock { $0.append(String(describing: err)) } }
        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(
                identity: .none(username: "race"),
                safe: safe,
                createRenderer: { opts in
                    factoryStarted.withLock { $0 = true }
                    await withCheckedContinuation { cont in
                        releaseFactory.withLock { $0 = cont }
                    }
                    let r = SSHHeadlessRenderer(options: opts)
                    lateRendererBox.withLock { $0 = r }
                    return r
                }
            )
        )

        let task = runSession(
            middlewares: [],
            handler: { _ in handlerRan.withLock { $0 = true } },
            bridge: bridge,
            safe: safe
        )

        #expect(await waitUntil { factoryStarted.withLock { $0 } && releaseFactory.withLock { $0 != nil } })
        channel.emitClose()
        #expect(await waitUntil { bridge.closed })
        releaseFactory.withLock { let c = $0; $0 = nil; return c }?.resume()

        await task.value
        await bridge.destroy()

        #expect(handlerRan.withLock { $0 } == false)
        #expect(errors.withLock { $0 }.isEmpty)
        #expect(lateRendererBox.withLock { $0?.isDestroyed } == true)
    }

    @Test("onClose after close fires immediately once; destroy is idempotent; write after close is a no-op")
    func idempotentDestroyAndLateCallbacks() async throws {
        let channel = InMemorySSHChannel()
        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(identity: .none(username: "u"))
        )
        let closeCount = Mutex(0)
        _ = bridge.session.onClose { closeCount.withLock { $0 += 1 } }

        await bridge.destroy()
        await bridge.destroy()
        try bridge.session.write("ignored")

        #expect(closeCount.withLock { $0 } == 1)
        #expect(channel.exits == [0])
        #expect(channel.closeCalls == 1)
        #expect(channel.writtenText == "")

        let lateRan = Mutex(false)
        _ = bridge.session.onClose { lateRan.withLock { $0 = true } }
        #expect(lateRan.withLock { $0 } == true)

        let resizeRan = Mutex(false)
        _ = bridge.session.onResize { _, _ in resizeRan.withLock { $0 = true } }
        bridge.resize(cols: 90, rows: 30)
        #expect(resizeRan.withLock { $0 } == false)
    }

    @Test("isClientEnvValue enforces UTF-8 byte cap and rejects NUL bytes")
    func clientEnvValidation() {
        let exactly256 = String(repeating: "é", count: 128) // 128 * 2 UTF-8 bytes = 256
        #expect(isClientEnvValue(exactly256) == true)
        #expect(isClientEnvValue("x" + exactly256) == false)
        #expect(isClientEnvValue("truecolor\u{0000}") == false)
    }
}

// MARK: - Connection, Middleware Pipeline & Server Integration

@Suite("SSH Connection & Server")
struct SSHConnectionAndServerTests {
    @Test("Middleware onion ordering, context bag propagation, double-next rejection, and deny unwinding")
    func middlewarePipeline() async {
        let order = Mutex<[String]>([])
        let errors = Mutex<[String]>([])
        let safe = createSafeInvoke { err in errors.withLock { $0.append(String(describing: err)) } }

        // 1. Onion order + typed and named context propagation
        do {
            let channel = InMemorySSHChannel()
            let bridge = createSessionBridge(
                channel: channel,
                options: SSHSessionBridgeOptions(identity: .none(username: "alice"), safe: safe)
            )
            let task = runSession(
                middlewares: [
                    { _, next in
                        order.withLock { $0.append("mw1-before") }
                        defer { order.withLock { $0.append("mw1-after") } }
                        return try await next(UserContextKey.self, value: "alice-id")
                    },
                    { session, next in
                        order.withLock { $0.append("mw2-before:\(session.context[UserContextKey.self] ?? "")") }
                        defer { order.withLock { $0.append("mw2-after") } }
                        return try await next(["tenant": "acme"])
                    },
                ],
                handler: { session in
                    let user = session.context[UserContextKey.self] ?? ""
                    let tenant = (session.context["tenant"] as? String) ?? ""
                    order.withLock { $0.append("handler:\(user)/\(tenant)") }
                    session.end()
                },
                bridge: bridge,
                safe: safe
            )
            await task.value
            await bridge.destroy()

            #expect(order.withLock { $0 } == [
                "mw1-before",
                "mw2-before:alice-id",
                "handler:alice-id/acme",
                "mw2-after",
                "mw1-after",
            ])
            #expect(errors.withLock { $0 }.isEmpty)
        }

        // 2. Calling next() twice reports an error via safe
        do {
            let channel = InMemorySSHChannel()
            let bridge = createSessionBridge(
                channel: channel,
                options: SSHSessionBridgeOptions(identity: .none(username: "dup"), safe: safe)
            )
            let task = runSession(
                middlewares: [
                    { _, next in
                        _ = try await next()
                        return try await next()
                    },
                ],
                handler: { session in session.end() },
                bridge: bridge,
                safe: safe
            )
            await task.value
            await bridge.destroy()
            #expect(errors.withLock { $0.contains { $0.contains("next() called more than once") } })
        }
    }

    @Test("resolveRuntime validates durations, session limits, and auth config")
    func runtimeValidation() throws {
        let pair = generateEd25519KeyPair()
        let rt = try resolveRuntime(SSHServerConfig(
            hostKey: .pem(pair.privatePem),
            idleTimeout: "10m",
            maxTimeout: 750,
            limits: SSHLimitsConfig(session: SSHSessionLimitsConfig(perConnection: 3, global: 25))
        ))
        #expect(rt.idleTimeoutMs == 600_000)
        #expect(rt.maxTimeoutMs == 750)
        #expect(rt.sessionLimits == SSHResolvedSessionLimits(perConnection: 3, global: 25))
        #expect(rt.noneOnly == true)

        #expect(try resolveRuntime(SSHServerConfig(hostKey: .pem(pair.privatePem), idleTimeout: "24h")).idleTimeoutMs == 86_400_000)

        for badTimeout in [SSHDuration.string("soon"), .string(""), .milliseconds(0), .milliseconds(-1), .milliseconds(86_400_001)] {
            #expect(throws: ConfigError.self) {
                _ = try resolveRuntime(SSHServerConfig(hostKey: .pem(pair.privatePem), idleTimeout: badTimeout))
            }
        }
        #expect(throws: ConfigError.self) {
            _ = try resolveRuntime(SSHServerConfig(
                hostKey: .pem(pair.privatePem),
                limits: SSHLimitsConfig(session: SSHSessionLimitsConfig(perConnection: 0))
            ))
        }
        #expect(throws: ConfigError.self) {
            _ = try resolveRuntime(SSHServerConfig(
                hostKey: .pem(pair.privatePem),
                limits: SSHLimitsConfig(session: SSHSessionLimitsConfig(global: -2))
            ))
        }
    }

    @Test("Full-stack SSHServer lifecycle via InMemorySSHTransportDriver: auth, env, PTY, limits, warning, and close")
    func fullStackServerLifecycle() async throws {
        let driver = InMemorySSHTransportDriver()
        let banners = Mutex<[[String]]>([])
        let warnings = Mutex<[String]>([])
        let handledSessions = Mutex<[String]>([])
        let activeSessionsInsideHandler = Mutex<[any SSHSession]>([])

        let server = try createSSHServer(
            config: SSHServerConfig(
                auth: .methods(SSHAuthMethods(
                    password: { ctx in ctx.username == "alice" && timingSafeEqual(ctx.password, "secret") }
                )),
                limits: SSHLimitsConfig(session: SSHSessionLimitsConfig(perConnection: 1, global: 2)),
                startupBanner: true,
                bannerSink: { lines in banners.withLock { $0.append(lines) } },
                warningSink: { msg in warnings.withLock { $0.append(msg) } }
            ),
            driver: driver
        )
        .use(sshLogging(options: SSHLoggingOptions(lineSink: { _ in })))
        .use { session, next in
            if session.identity.username == "blocked" {
                try session.deny("access denied")
            }
            return try await next(RoleContextKey.self, value: ["admin"])
        }
        .handle { session in
            let roles = session.context[RoleContextKey.self] ?? []
            handledSessions.withLock { $0.append("\(session.identity.username):\(roles.joined(separator: ",")):\(session.cols)x\(session.rows):\(session.hasPty)") }
            activeSessionsInsideHandler.withLock { $0.append(session) }
            try session.write("HELLO \(session.identity.username)\r\n")
        }

        let listenInfo = try await server.listen(port: 0, host: "127.0.0.1")
        #expect(listenInfo.host == "127.0.0.1")
        #expect(listenInfo.port >= 22000)
        #expect(listenInfo.fingerprints.count == 1)
        #expect(server.address == listenInfo)
        #expect(banners.withLock { $0.count } == 1)
        #expect(warnings.withLock { $0 }.isEmpty) // credentialed server never emits open warning

        // Client connects & authenticates
        let client1 = driver.connect(remoteAddress: SSHRemoteAddress(address: "::ffff:127.0.0.1", port: 44444))
        #expect(client1.noDelayHistory == [true])
        #expect(server.connections == 1)

        // Wrong password rejected with advertised methods
        let badAuth = await client1.authenticate(method: "password", username: "alice", password: "wrong")
        #expect(badAuth == .rejected([.password]))

        // Right password accepted
        let goodAuth = await client1.authenticate(method: "password", username: "alice", password: "secret")
        #expect(goodAuth == .accepted)
        client1.emitReady()

        let sshSession = client1.openSession()
        #expect(sshSession.requestEnv(key: "COLORTERM", value: "truecolor") == true)
        #expect(sshSession.requestEnv(key: "PATH", value: "/evil") == false) // disallowed env key
        #expect(sshSession.requestEnv(key: "TERM_PROGRAM", value: "bad\u{0000}") == false) // NUL rejected
        #expect(sshSession.requestPty(term: "xterm-256color", cols: 100, rows: 35) == true)

        let ch1 = sshSession.requestShell()
        #expect(ch1 != nil)
        // Env after shell rejected
        #expect(sshSession.requestEnv(key: "TERM_PROGRAM", value: "ghostty") == false)
        // Second shell on same connection exceeds perConnection limit (1)
        #expect(client1.openSession().requestShell() == nil)

        #expect(await waitUntil { ch1?.writtenText == "HELLO alice\r\n" })
        #expect(handledSessions.withLock { $0 } == ["alice:admin:100x35:true"])
        #expect(server.activeSessions == 1)

        // Window resize propagates to live session
        sshSession.sendWindowChange(cols: 120, rows: 45)
        #expect(await waitUntil { activeSessionsInsideHandler.withLock { $0.first?.cols == 120 && $0.first?.rows == 45 } })

        // Graceful server shutdown tears down active bridges & closes clients
        await server.close()
        #expect(server.address == nil)
        #expect(server.connections == 0)
        #expect(server.activeSessions == 0)
        #expect(driver.isListening == false)
        #expect(client1.endCalls == 1)
        #expect(client1.forceCloseCalls == 1)
        #expect(ch1?.exits == [0])
    }

    @Test("Open server on non-loopback host emits a warning without throwing")
    func openServerNonLoopbackWarning() async throws {
        let driver = InMemorySSHTransportDriver()
        let warnings = Mutex<[String]>([])
        let server = try createSSHServer(
            config: SSHServerConfig(
                auth: .open,
                startupBanner: false,
                warningSink: { w in warnings.withLock { $0.append(w) } }
            ),
            driver: driver
        ).serve { session in
            session.end()
        }

        _ = try await server.listen(port: 0, host: "0.0.0.0")
        #expect(warnings.withLock { $0.count } == 1)
        #expect(warnings.withLock { $0[0].contains("no authentication configured") })
        await server.close()
    }

    @Test("Connection handles setNoDelay failure, late auth after close, bare-shell env, and signal forwarding")
    func connectionEdgeCases() async {
        let errors = Mutex<[String]>([])
        let signals = Mutex<[String]>([])
        let bareShellEnv = Mutex<[String: String]?>(nil)
        let safe = createSafeInvoke { err in errors.withLock { $0.append(String(describing: err)) } }

        let connHandler = createConnectionHandler(SSHConnectionDependencies(
            authenticator: createAuthenticator(auth: SSHNormalizedAuthConfig(none: true)),
            middlewares: [],
            handler: { session in
                if let headless = session.renderer as? SSHHeadlessRenderer {
                    bareShellEnv.withLock { $0 = headless.environment }
                }
            },
            safe: safe,
            sessionLimits: SSHResolvedSessionLimits(perConnection: 2, global: 4),
            onSignal: { _, sig in signals.withLock { $0.append(sig) } }
        ))
        connHandler.setAccepting(true)

        // 1. setNoDelay throws after emitting close -> error reported, connection cleaned up
        let failingClient = InMemorySSHClientConnection(
            noDelayHook: { client, _ in
                client.emitClose()
                throw TestFailure(message: "nodelay-failed")
            }
        )
        connHandler.onConnection(failingClient)
        #expect(errors.withLock { $0 } == ["nodelay-failed"])
        #expect(connHandler.connectionCount == 0)

        // 2. Bare shell (no PTY) receives empty renderer environment even if COLORTERM was sent,
        // and signal forwarding reaches onSignal
        let bareClient = InMemorySSHClientConnection()
        connHandler.onConnection(bareClient)
        let authRes = await bareClient.authenticate(method: "none", username: "bare")
        #expect(authRes == .accepted)
        bareClient.emitReady()

        let sshSession = bareClient.openSession()
        #expect(sshSession.requestEnv(key: "COLORTERM", value: "truecolor") == true)
        let ch = sshSession.requestShell()
        #expect(ch != nil)
        #expect(await waitUntil { bareShellEnv.withLock { $0 != nil } })
        #expect(bareShellEnv.withLock { $0 } == [:])

        sshSession.sendSignal("TERM")
        #expect(signals.withLock { $0 } == ["TERM"])

        await connHandler.closeAll()
        #expect(connHandler.connectionCount == 0)
    }

    @Test("Middleware deny skips renderer attachment, reports no error, and still emits logging disconnect")
    func middlewareDenyAndLoggingTeardown() async {
        let rendererCreated = Mutex(false)
        let handlerRan = Mutex(false)
        let errors = Mutex<[String]>([])
        let events = Mutex<[String]>([])
        let channel = InMemorySSHChannel()
        let safe = createSafeInvoke { err in errors.withLock { $0.append(String(describing: err)) } }

        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(
                identity: .none(username: "blocked"),
                safe: safe,
                createRenderer: { opts in
                    rendererCreated.withLock { $0 = true }
                    return SSHHeadlessRenderer(options: opts)
                }
            )
        )

        let task = runSession(
            middlewares: [
                sshLogging(options: SSHLoggingOptions(log: { ev in
                    events.withLock { $0.append(ev.type) }
                })),
                { session, _ in
                    try session.deny("banned")
                },
            ],
            handler: { _ in handlerRan.withLock { $0 = true } },
            bridge: bridge,
            safe: safe
        )

        await task.value
        await bridge.destroy()

        #expect(rendererCreated.withLock { $0 } == false)
        #expect(handlerRan.withLock { $0 } == false)
        #expect(errors.withLock { $0 }.isEmpty)
        #expect(events.withLock { $0 } == ["connect", "disconnect"])
        #expect(channel.writtenText == "banned\r\n")
    }

    @Test("Genuine renderer creation failure tears down session and reports error once")
    func rendererCreationFailureReported() async {
        let errors = Mutex<[String]>([])
        let handlerRan = Mutex(false)
        let channel = InMemorySSHChannel()
        let safe = createSafeInvoke { err in errors.withLock { $0.append(String(describing: err)) } }

        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(
                identity: .none(username: "u"),
                safe: safe,
                createRenderer: { _ in
                    throw TestFailure(message: "renderer init failed")
                }
            )
        )

        let task = runSession(
            middlewares: [],
            handler: { _ in handlerRan.withLock { $0 = true } },
            bridge: bridge,
            safe: safe
        )

        await task.value
        await bridge.destroy()

        #expect(handlerRan.withLock { $0 } == false)
        #expect(bridge.closed == true)
        #expect(errors.withLock { $0 } == ["renderer init failed"])
    }

    @Test("Idle timeout and maxTimeout reap inactive and long-lived sessions")
    func sessionTimeoutReaping() async {
        // Max timeout reaps session automatically
        let channel = InMemorySSHChannel()
        let bridge = createSessionBridge(
            channel: channel,
            options: SSHSessionBridgeOptions(
                identity: .none(username: "timer"),
                maxTimeoutMs: 40
            )
        )
        #expect(bridge.closed == false)
        #expect(await waitUntil(timeoutMs: 1_000) { bridge.closed })
        await bridge.destroy()
        #expect(channel.exits == [0])

        // Idle timeout reaps after quiet period
        let idleChannel = InMemorySSHChannel()
        let idleBridge = createSessionBridge(
            channel: idleChannel,
            options: SSHSessionBridgeOptions(
                identity: .none(username: "idle"),
                idleTimeoutMs: 40
            )
        )
        #expect(await waitUntil(timeoutMs: 1_000) { idleBridge.closed })
        await idleBridge.destroy()
        #expect(idleChannel.exits == [0])
    }
}

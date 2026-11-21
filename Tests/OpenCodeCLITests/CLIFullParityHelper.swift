import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Synchronization
import OpenCodeCLIKit
import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Fixtures, mock server payloads, and POSIX PTY helpers for `CLIFullParityTests`
/// (kept separate from `import Testing` per macOS CLT cross-import rule).
enum CLIFullParityFixtures {
    static func richModelsEnvelopeJSON() -> String {
        let anthropic = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "claude-sonnet-4"),
            modelID: ModelSchema.ID(rawValue: "claude-sonnet-4"),
            providerID: ProviderSchema.ID(rawValue: "anthropic"),
            name: "Claude Sonnet 4",
            capabilities: ModelSchema.Capabilities(
                tools: true,
                input: ["text", "image", "pdf"],
                output: ["text"],
                temperature: true
            ),
            variants: [
                ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "high")),
                ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "max")),
            ],
            time: ModelSchema.Info.Time(released: 1_747_872_000_000),
            cost: [
                ModelSchema.Cost(
                    input: MoneySchema.USDPerMillionTokens(rawValue: 3.0)!,
                    output: MoneySchema.USDPerMillionTokens(rawValue: 15.0)!,
                    cache: ModelSchema.Cost.Cache(
                        read: MoneySchema.USDPerMillionTokens(rawValue: 0.3)!,
                        write: MoneySchema.USDPerMillionTokens(rawValue: 3.75)!
                    )
                ),
            ],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 200_000, output: 64_000)
        )
        let openai = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gpt-5"),
            modelID: ModelSchema.ID(rawValue: "gpt-5"),
            providerID: ProviderSchema.ID(rawValue: "openai"),
            name: "GPT-5",
            capabilities: ModelSchema.Capabilities(
                tools: true,
                input: ["text", "image"],
                output: ["text"]
            ),
            variants: [
                ModelSchema.Variant(id: ModelSchema.VariantID(rawValue: "medium")),
            ],
            time: ModelSchema.Info.Time(released: 1_754_524_800_000),
            cost: [
                ModelSchema.Cost(
                    input: MoneySchema.USDPerMillionTokens(rawValue: 2.5)!,
                    output: MoneySchema.USDPerMillionTokens(rawValue: 10.0)!,
                    cache: ModelSchema.Cost.Cache(
                        read: MoneySchema.USDPerMillionTokens(rawValue: 0.25)!,
                        write: MoneySchema.USDPerMillionTokens(rawValue: 2.5)!
                    )
                ),
            ],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 400_000, output: 128_000)
        )
        let google = ModelSchema.Info(
            id: ModelSchema.ID(rawValue: "gemini-2.5-pro"),
            modelID: ModelSchema.ID(rawValue: "gemini-2.5-pro"),
            providerID: ProviderSchema.ID(rawValue: "google"),
            name: "Gemini 2.5 Pro",
            capabilities: ModelSchema.Capabilities(
                tools: true,
                input: ["text", "image", "audio"],
                output: ["text"]
            ),
            variants: [],
            time: ModelSchema.Info.Time(released: 1_742_860_800_000),
            cost: [],
            status: .active,
            enabled: true,
            limit: ModelSchema.Info.Limit(context: 1_000_000, output: 65_536)
        )
        let envelope = LocationSchema.ResponseEnvelope(
            location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace/project")),
            data: [openai, google, anthropic]
        )
        return (try? CLITestFixtures.encodeJSON(envelope)) ?? "{}"
    }

    static func authIntegrationsEnvelopeJSON() -> String {
        let integrations: [IntegrationSchema.Info] = [
            IntegrationSchema.Info(
                id: IntegrationID(rawValue: "anthropic"),
                name: "Anthropic",
                metadata: nil,
                methods: [
                    .key(IntegrationSchema.KeyMethod(label: "Enter your Anthropic API key")),
                ],
                connections: [
                    .env(ConnectionSchema.EnvInfo(name: "ANTHROPIC_API_KEY")),
                ]
            ),
            IntegrationSchema.Info(
                id: IntegrationID(rawValue: "openai"),
                name: "OpenAI",
                metadata: nil,
                methods: [
                    .oauth(IntegrationSchema.OAuthMethod(id: IntegrationMethodID(rawValue: "chatgpt"), label: "ChatGPT Plus")),
                    .key(IntegrationSchema.KeyMethod(label: "API Key")),
                ],
                connections: [
                    .credential(ConnectionSchema.CredentialInfo(id: CredentialSchema.ID(rawValue: "crd_1"), label: "Personal", method: .key)),
                    .credential(ConnectionSchema.CredentialInfo(id: CredentialSchema.ID(rawValue: "crd_2"), label: "Work", method: .oauth)),
                ]
            ),
        ]
        let envelope = LocationSchema.ResponseEnvelope(
            location: LocationSchema.PublicRef(directory: SchemaPrimitive.AbsolutePath(rawValue: "/workspace/project")),
            data: integrations
        )
        return (try? CLITestFixtures.encodeJSON(envelope)) ?? "{}"
    }

    static func sampleCredentialsJSON() -> String {
        let entries: [CredentialSchema.Entry] = [
            CredentialSchema.Entry(
                id: CredentialSchema.ID(rawValue: "crd_1"),
                integrationID: IntegrationID(rawValue: "openai"),
                label: "Personal",
                active: true,
                value: .key(CredentialSchema.Key(key: "sk-test-openai-1"))
            ),
            CredentialSchema.Entry(
                id: CredentialSchema.ID(rawValue: "crd_new_99"),
                integrationID: IntegrationID(rawValue: "anthropic"),
                label: "Work Anthropic",
                active: true,
                value: .key(CredentialSchema.Key(key: "sk-ant-test-99"))
            ),
        ]
        return (try? CLITestFixtures.encodeJSON(entries)) ?? "[]"
    }

    static func sampleSessionExportJSON(id: String = "ses_export01", title: String = "Exported\nSession\tTitle") -> String {
        let info = SessionSchema.Info(
            id: SessionID(rawValue: id)!,
            projectID: ProjectID(rawValue: "prj_test0001"),
            cost: 0.12,
            tokens: SessionSchema.TokenUsage(input: 1000, output: 500, reasoning: 0, cache: .init(read: 0, write: 0)),
            time: SessionSchema.Info.Time(created: 1_735_689_600_000, updated: 1_735_689_900_000),
            title: title,
            location: SessionSchema.LocationRef(directory: "/workspace/project")
        )
        let data = SessionTransferSchema.Data(info: info, messages: [])
        return (try? CLITestFixtures.encodeJSON(data)) ?? "{}"
    }

    static func sampleServiceRegistrationFiles(
        url: String = "http://127.0.0.1:49374",
        version: String = "2.1.0",
        pid: Int = 4242,
        password: String = "pair-secret",
        includeRemoteConfig: Bool = false
    ) -> [String: String] {
        let info = ServiceInfo(id: "svc_test", version: version, url: url, pid: pid, password: password)
        let json = (try? CLITestFixtures.encodeJSON(info)) ?? "{}"
        var files: [String: String] = [
            "/home/tester/.local/state/opencode/service.json": json,
        ]
        if includeRemoteConfig {
            files["/home/tester/.config/opencode/service.json"] = "{\"remote\":{\"route\":\"test-route\"},\"remoteAccepted\":true}"
        }
        return files
    }

    static func expectedPairingQR(code: String, urls: [String]) throws -> String {
        let payload = JSONValue.object([
            "code": .string(code),
            "urls": .array(urls.map(JSONValue.string)),
        ])
        let encoded = try CLITestFixtures.encodeJSON(payload)
        return try QR.renderUnicodeCompact(encoded, border: 2)
    }

    static func decodeUTF8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    static func makeBufferedIO(
        stdinLines: [String],
        isStdinTTY: Bool = false,
        isStdoutTTY: Bool = false,
        columns: Int = 80,
        rows: Int = 24
    ) -> (io: CLIIO, output: CLIBufferedOutput) {
        let output = CLIBufferedOutput()
        let io = CLIIO.buffered(
            output: output,
            stdinLines: stdinLines,
            isStdinTTY: isStdinTTY,
            isStdoutTTY: isStdoutTTY,
            columns: columns,
            rows: rows
        )
        return (io, output)
    }

    static func makeByteReader(from bytes: [UInt8]) -> @Sendable (_ timeoutMs: Int32?) -> UInt8? {
        let state = Mutex(0)
        return { _ in
            state.withLock { idx -> UInt8? in
                guard idx < bytes.count else { return nil }
                let value = bytes[idx]
                idx += 1
                return value
            }
        }
    }

    static func makeKeyReader(from keys: [CLIUI.Prompt.TerminalKey]) -> @Sendable () -> CLIUI.Prompt.TerminalKey? {
        let state = Mutex(0)
        return {
            state.withLock { idx -> CLIUI.Prompt.TerminalKey? in
                guard idx < keys.count else { return nil }
                let value = keys[idx]
                idx += 1
                return value
            }
        }
    }

    // MARK: - Real POSIX PTY & Termios Verification Helpers

    struct POSIXTermiosCheckResult: Equatable, Sendable {
        let supported: Bool
        let hadEchoBefore: Bool
        let echoDisabledInside: Bool
        let canonicalDisabledInside: Bool
        let isigDisabledInside: Bool
        let restoredAfterNormalReturn: Bool
        let restoredAfterThrow: Bool
        let maskedPasswordResult: String
        let maskedPasswordStderr: String
        let echoRestoredAfterPassword: Bool
        let cancelledOnCtrlC: Bool
        let cancelledStderrHasNewline: Bool
        let echoRestoredAfterCancel: Bool
    }

    static func runPOSIXTermiosAndPTYChecks() -> POSIXTermiosCheckResult {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        // 1. Pure struct test on makeNoEchoRawTermios
        var sampleTerm = termios()
        sampleTerm.c_lflag = tcflag_t(ECHO) | tcflag_t(ECHONL) | tcflag_t(ICANON) | tcflag_t(ISIG)
        let rawCopy = CLIUI.Prompt.DefaultTerminalBackend.makeNoEchoRawTermios(from: sampleTerm)
        let pureEchoOff = (rawCopy.c_lflag & tcflag_t(ECHO)) == 0
        let pureCanonOff = (rawCopy.c_lflag & tcflag_t(ICANON)) == 0
        let pureIsigOff = (rawCopy.c_lflag & tcflag_t(ISIG)) == 0

        // 2. Real POSIX PTY pair for live tcgetattr/tcsetattr + defer restore + readPOSIXPassword
        let masterFD: Int32
        let slaveFD: Int32
        #if canImport(Darwin)
        let openedMaster = posix_openpt(O_RDWR | O_NOCTTY)
        guard openedMaster >= 0 else {
            return POSIXTermiosCheckResult(
                supported: false,
                hadEchoBefore: true,
                echoDisabledInside: pureEchoOff,
                canonicalDisabledInside: pureCanonOff,
                isigDisabledInside: pureIsigOff,
                restoredAfterNormalReturn: false,
                restoredAfterThrow: false,
                maskedPasswordResult: "",
                maskedPasswordStderr: "",
                echoRestoredAfterPassword: false,
                cancelledOnCtrlC: false,
                cancelledStderrHasNewline: false,
                echoRestoredAfterCancel: false
            )
        }
        guard grantpt(openedMaster) == 0, unlockpt(openedMaster) == 0, let slaveNamePtr = ptsname(openedMaster) else {
            _ = close(openedMaster)
            return POSIXTermiosCheckResult(
                supported: false,
                hadEchoBefore: true,
                echoDisabledInside: pureEchoOff,
                canonicalDisabledInside: pureCanonOff,
                isigDisabledInside: pureIsigOff,
                restoredAfterNormalReturn: false,
                restoredAfterThrow: false,
                maskedPasswordResult: "",
                maskedPasswordStderr: "",
                echoRestoredAfterPassword: false,
                cancelledOnCtrlC: false,
                cancelledStderrHasNewline: false,
                echoRestoredAfterCancel: false
            )
        }
        let openedSlave = open(slaveNamePtr, O_RDWR | O_NOCTTY)
        guard openedSlave >= 0 else {
            _ = close(openedMaster)
            return POSIXTermiosCheckResult(
                supported: false,
                hadEchoBefore: true,
                echoDisabledInside: pureEchoOff,
                canonicalDisabledInside: pureCanonOff,
                isigDisabledInside: pureIsigOff,
                restoredAfterNormalReturn: false,
                restoredAfterThrow: false,
                maskedPasswordResult: "",
                maskedPasswordStderr: "",
                echoRestoredAfterPassword: false,
                cancelledOnCtrlC: false,
                cancelledStderrHasNewline: false,
                echoRestoredAfterCancel: false
            )
        }
        masterFD = openedMaster
        slaveFD = openedSlave
        #else
        var openedMaster: Int32 = -1
        var openedSlave: Int32 = -1
        guard openpty(&openedMaster, &openedSlave, nil, nil, nil) == 0 else {
            return POSIXTermiosCheckResult(
                supported: false,
                hadEchoBefore: true,
                echoDisabledInside: pureEchoOff,
                canonicalDisabledInside: pureCanonOff,
                isigDisabledInside: pureIsigOff,
                restoredAfterNormalReturn: false,
                restoredAfterThrow: false,
                maskedPasswordResult: "",
                maskedPasswordStderr: "",
                echoRestoredAfterPassword: false,
                cancelledOnCtrlC: false,
                cancelledStderrHasNewline: false,
                echoRestoredAfterCancel: false
            )
        }
        masterFD = openedMaster
        slaveFD = openedSlave
        #endif
        defer { close(masterFD) }
        defer { close(slaveFD) }

        var initialTerm = termios()
        _ = tcgetattr(slaveFD, &initialTerm)
        initialTerm.c_lflag |= tcflag_t(ECHO) | tcflag_t(ICANON) | tcflag_t(ISIG)
        _ = tcsetattr(slaveFD, TCSANOW, &initialTerm)
        _ = tcgetattr(slaveFD, &initialTerm)
        let hadEchoBefore = (initialTerm.c_lflag & tcflag_t(ECHO)) != 0

        var echoDisabledInside = false
        var canonicalDisabledInside = false
        var isigDisabledInside = false
        _ = try? CLIUI.Prompt.DefaultTerminalBackend.withNoEchoRawMode(fd: slaveFD) {
            var during = termios()
            if tcgetattr(slaveFD, &during) == 0 {
                echoDisabledInside = (during.c_lflag & tcflag_t(ECHO)) == 0
                canonicalDisabledInside = (during.c_lflag & tcflag_t(ICANON)) == 0
                isigDisabledInside = (during.c_lflag & tcflag_t(ISIG)) == 0
            }
        }
        let modeMask = tcflag_t(ECHO) | tcflag_t(ECHONL) | tcflag_t(ICANON) | tcflag_t(ISIG)
        var afterNormal = termios()
        _ = tcgetattr(slaveFD, &afterNormal)
        let restoredAfterNormalReturn = (afterNormal.c_lflag & modeMask) == (initialTerm.c_lflag & modeMask)

        do {
            try CLIUI.Prompt.DefaultTerminalBackend.withNoEchoRawMode(fd: slaveFD) {
                throw CLIUI.Prompt.CancelledError()
            }
        } catch {
            // Expected throw to verify defer restoration
        }
        var afterThrow = termios()
        _ = tcgetattr(slaveFD, &afterThrow)
        let restoredAfterThrow = (afterThrow.c_lflag & modeMask) == (initialTerm.c_lflag & modeMask)

        // 3. Feed masked password bytes ("ab", backspace, "cd\r") through PTY master
        //    the instant readPOSIXPassword prints its prompt (after tcsetattr disables ECHO/ICANON/ISIG).
        let inputBytes: [UInt8] = [0x61, 0x62, 0x7F, 0x63, 0x64, 0x0D]
        var pwStderr = ""
        var pwSent = false
        let pwResult = (try? CLIUI.Prompt.DefaultTerminalBackend.readPOSIXPassword(
            prompt: "API Key: ",
            fd: slaveFD,
            writeStderr: { chunk in
                pwStderr += chunk
                if !pwSent {
                    pwSent = true
                    _ = inputBytes.withUnsafeBytes { buf in
                        #if canImport(Darwin)
                        Darwin.write(masterFD, buf.baseAddress, buf.count)
                        #elseif canImport(Glibc)
                        Glibc.write(masterFD, buf.baseAddress, buf.count)
                        #elseif canImport(Musl)
                        Musl.write(masterFD, buf.baseAddress, buf.count)
                        #endif
                    }
                }
            }
        )) ?? ""
        var afterPw = termios()
        _ = tcgetattr(slaveFD, &afterPw)
        let echoRestoredAfterPassword = (afterPw.c_lflag & modeMask) == (initialTerm.c_lflag & modeMask)

        // 4. Feed Ctrl+C (0x03) through PTY master after prompt (ISIG is disabled inside raw mode)
        let cancelBytes: [UInt8] = [0x78, 0x03]
        var cancelStderr = ""
        var cancelSent = false
        var cancelledOnCtrlC = false
        do {
            _ = try CLIUI.Prompt.DefaultTerminalBackend.readPOSIXPassword(
                prompt: "Token: ",
                fd: slaveFD,
                writeStderr: { chunk in
                    cancelStderr += chunk
                    if !cancelSent {
                        cancelSent = true
                        _ = cancelBytes.withUnsafeBytes { buf in
                            #if canImport(Darwin)
                            Darwin.write(masterFD, buf.baseAddress, buf.count)
                            #elseif canImport(Glibc)
                            Glibc.write(masterFD, buf.baseAddress, buf.count)
                            #elseif canImport(Musl)
                            Musl.write(masterFD, buf.baseAddress, buf.count)
                            #endif
                        }
                    }
                }
            )
        } catch is CLIUI.Prompt.CancelledError {
            cancelledOnCtrlC = true
        } catch {
            cancelledOnCtrlC = false
        }
        var afterCancel = termios()
        _ = tcgetattr(slaveFD, &afterCancel)
        let echoRestoredAfterCancel = (afterCancel.c_lflag & modeMask) == (initialTerm.c_lflag & modeMask)

        return POSIXTermiosCheckResult(
            supported: true,
            hadEchoBefore: hadEchoBefore,
            echoDisabledInside: pureEchoOff && echoDisabledInside,
            canonicalDisabledInside: pureCanonOff && canonicalDisabledInside,
            isigDisabledInside: pureIsigOff && isigDisabledInside,
            restoredAfterNormalReturn: restoredAfterNormalReturn,
            restoredAfterThrow: restoredAfterThrow,
            maskedPasswordResult: pwResult,
            maskedPasswordStderr: pwStderr,
            echoRestoredAfterPassword: echoRestoredAfterPassword,
            cancelledOnCtrlC: cancelledOnCtrlC,
            cancelledStderrHasNewline: cancelStderr.hasSuffix("\n"),
            echoRestoredAfterCancel: echoRestoredAfterCancel
        )
        #else
        return POSIXTermiosCheckResult(
            supported: false,
            hadEchoBefore: false,
            echoDisabledInside: false,
            canonicalDisabledInside: false,
            isigDisabledInside: false,
            restoredAfterNormalReturn: false,
            restoredAfterThrow: false,
            maskedPasswordResult: "",
            maskedPasswordStderr: "",
            echoRestoredAfterPassword: false,
            cancelledOnCtrlC: false,
            cancelledStderrHasNewline: false,
            echoRestoredAfterCancel: false
        )
        #endif
    }
}

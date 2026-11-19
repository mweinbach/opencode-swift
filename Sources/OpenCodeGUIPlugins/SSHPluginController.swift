import Foundation
import OpenCodePlatform
import OpenCodeUtil

// MARK: - SSH Contract (`ssh/contract.ts`)

public struct SSHConfig: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let target: String
    public let name: String

    public init(id: String, target: String, name: String) {
        self.id = id
        self.target = target
        self.name = name
    }
}

public struct SSHHttp: Equatable, Hashable, Sendable, Codable {
    public let url: String
    public let password: String

    public init(url: String, password: String) {
        self.url = url
        self.password = password
    }
}

public enum SSHStage: String, Equatable, Hashable, Sendable, Codable {
    case disconnected
    case connecting
    case ready
    case authentication
    case incompatible
    case failed
}

public struct SSHPrompt: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let text: String
    public let confirm: Bool

    public init(id: String, text: String, confirm: Bool) {
        self.id = id
        self.text = text
        self.confirm = confirm
    }
}

public enum SSHError: String, Equatable, Hashable, Sendable, Codable {
    case connection
    case input
    case platform
    case version
    case install
    case service
    case hostKey = "host-key"
    case sshMissing = "ssh-missing"
    case unpublished
}

public struct SSHItem: Equatable, Hashable, Sendable, Codable {
    public let config: SSHConfig
    public let saved: Bool
    public let destination: String?
    public let stage: SSHStage
    /// Set only while `stage` is `.ready`.
    public let http: SSHHttp?
    public let prompt: SSHPrompt?
    public let authenticatingElsewhere: Bool?
    /// A `.failed` server that main reconnects by itself; without it, the server waits for the user.
    public let retrying: Bool?
    public let detail: String
    public let error: SSHError?

    public init(
        config: SSHConfig,
        saved: Bool,
        destination: String? = nil,
        stage: SSHStage,
        http: SSHHttp? = nil,
        prompt: SSHPrompt? = nil,
        authenticatingElsewhere: Bool? = nil,
        retrying: Bool? = nil,
        detail: String = "",
        error: SSHError? = nil
    ) {
        self.config = config
        self.saved = saved
        self.destination = destination
        self.stage = stage
        self.http = http
        self.prompt = prompt
        self.authenticatingElsewhere = authenticatingElsewhere
        self.retrying = retrying
        self.detail = detail
        self.error = error
    }
}

/// `revision` grows with every push, so a caller can wait for the state that follows its request.
public struct SSHState: Equatable, Sendable, Codable {
    public let servers: [SSHItem]
    public let revision: Int

    public init(servers: [SSHItem], revision: Int) {
        self.servers = servers
        self.revision = revision
    }
}

public struct SSHStart: Equatable, Hashable, Sendable, Codable {
    public let id: String
    public let target: String
    public let name: String
    public let replace: Bool?
    public let background: Bool?

    public init(
        id: String,
        target: String,
        name: String,
        replace: Bool? = nil,
        background: Bool? = nil
    ) {
        self.id = id
        self.target = target
        self.name = name
        self.replace = replace
        self.background = background
    }
}

// MARK: - SSH Naming & Server State (`ssh/name.ts`)

public enum SSHNaming {
    /// Extracts the display hostname from an accepted SSH target string.
    public static func hostname(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard let last = parts.last else { return "" }
        let unquoted = String(last).filter { $0 != "\"" && $0 != "'" && $0 != "\\" }
        return unquoted.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    }

    public static func name(_ config: SSHConfig) -> String {
        config.name.isEmpty ? hostname(config.target) : config.name
    }

    /// Maps an `SSHItem` into the generic GUI `GUIServerState`.
    /// Another window answering the challenge reads as `.starting` here, not as a prompt of its own.
    public static func serverState(_ item: SSHItem) -> GUIServerState {
        if item.stage == .connecting || item.authenticatingElsewhere == true {
            return .starting
        }
        if item.stage == .authentication {
            return .auth
        }
        switch item.stage {
        case .ready:
            return .ready
        case .failed:
            return .failed
        case .incompatible:
            return .incompatible
        case .disconnected, .connecting, .authentication:
            return .stopped
        }
    }
}

// MARK: - Remote CLI Scripts & Helpers (`ssh/remote-cli.ts`)

public struct RemoteCLIFailure: Error, Equatable, Hashable, Sendable {
    public enum Code: String, Equatable, Hashable, Sendable, Codable {
        case platform
        case version
        case install
    }

    public let code: Code
    public let detail: String

    public init(code: Code, detail: String = "") {
        self.code = code
        self.detail = detail
    }
}

public enum RemoteCLI {
    public struct CacheSpec: Equatable, Hashable, Sendable {
        public let directory: String
        public let prefix: String

        public init(directory: String, prefix: String) {
            self.directory = directory
            self.prefix = prefix
        }
    }

    public enum InstallSource: Equatable, Hashable, Sendable {
        case download(url: String)
        case archive
        case installer(binary: String?)
    }

    public static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public static func requireVersion(_ version: String) throws(RemoteCLIFailure) -> String {
        if version == "local" {
            return version
        }
        guard isValidVersion(version) else {
            throw RemoteCLIFailure(code: .version, detail: version)
        }
        return version
    }

    public static func discoverScript(fromPath: Bool = false, cache: CacheSpec? = nil) -> String {
        let pathExpr = fromPath ? "$(command -v opencode || true)" : "\"\""
        let cacheBlock: String
        if let cache {
            cacheBlock = """
            if [ -z "$cli" ]; then
              for binary in "$HOME"/\(quote(cache.directory))/\(quote(cache.prefix))*/opencode; do
                if [ -x "$binary" ]; then cli="$binary"; fi
              done
            fi

            """
        } else {
            cacheBlock = ""
        }
        return """
        cli=\(pathExpr)
        if [ -z "$cli" ] && [ -x "$HOME/.opencode/bin/opencode" ]; then cli="$HOME/.opencode/bin/opencode"; fi
        \(cacheBlock)if [ -n "$cli" ]; then printf '%s\\n' "$cli"; fi

        """
    }

    public static func versionScript(_ command: String) -> String {
        "if [ -x \(command) ]; then \(command) --version 2>/dev/null || true; fi\n"
    }

    public static func parseVersion(_ output: String) throws -> String? {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        guard let line = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces), !line.isEmpty
        else {
            return nil
        }
        let version: String
        if let range = line.range(of: " v", options: .backwards) {
            version = String(line[range.upperBound...])
        } else {
            version = line
        }
        if version.isEmpty {
            throw RemoteCLIFailure(code: .version, detail: "V2 CLI did not provide a version")
        }
        return version
    }

    public static let probeScript: String = """
    set -eu
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$os" in linux|darwin) ;; *) exit 2 ;; esac
    case "$arch" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) exit 2 ;; esac
    target="$os-$arch"
    if [ "$arch" = x64 ]; then target="$target-baseline"; fi
    if [ "$os" = linux ]; then
      if [ -f /etc/alpine-release ] || (ldd --version 2>&1 | grep -qi musl); then target="$target-musl"; fi
    fi
    printf 'OPENCODE_REMOTE_TARGET=%s\\n' "$target"

    """

    public static func archiveUrl(target: String, version: String) throws(RemoteCLIFailure) -> String {
        let validTargets: Set<String> = [
            "linux-x64-baseline",
            "linux-x64-baseline-musl",
            "linux-arm64",
            "linux-arm64-musl",
            "darwin-x64-baseline",
            "darwin-x64-baseline-musl",
            "darwin-arm64",
            "darwin-arm64-musl",
        ]
        guard validTargets.contains(target) else {
            throw RemoteCLIFailure(code: .platform, detail: target)
        }
        let validated = try requireVersion(version)
        return "https://registry.npmjs.org/@opencode/cli-\(target)/-/cli-\(target)-\(validated).tgz"
    }

    public static func installScript(
        version rawVersion: String,
        directory: String? = nil,
        source: InstallSource
    ) throws(RemoteCLIFailure) -> String {
        let version = try requireVersion(rawVersion)

        switch source {
        case .installer(let binary):
            let flag = binary.map { "--binary \($0)" } ?? "--version \(quote(version))"
            return """
            set -eu
            curl -fsSL https://raw.githubusercontent.com/anomalyco/opencode/v2/install | bash -s -- \(flag)
            \(verifyScript("\"$HOME/.opencode/bin/opencode\"", version: version))

            """
        case .download(let url):
            let destinationPath = "\(directory ?? ".opencode/bin")/opencode"
            let stage = """
            url=\(quote(url))
            if command -v curl >/dev/null 2>&1; then
              curl -fsSL --connect-timeout 15 --max-time 180 "$url" -o "$stage/archive.tgz"
            else
              wget -T 180 -O "$stage/archive.tgz" "$url"
            fi
            tar -xzf "$stage/archive.tgz" -C "$stage"
            """
            return """
            set -eu
            umask 077
            destination="$HOME"/\(quote(destinationPath))
            mkdir -p "$(dirname "$destination")"
            stage=$(mktemp -d "$(dirname "$destination")/.install-XXXXXX")
            trap 'rm -rf "$stage"' EXIT
            \(stage)
            chmod 755 "$stage/package/bin/opencode"
            \(verifyScript("\"$stage/package/bin/opencode\"", version: version))
            mv "$stage/package/bin/opencode" "$destination"

            """
        case .archive:
            let destinationPath = "\(directory ?? ".opencode/bin")/opencode"
            let stage = """
            cat > "$stage/archive.tgz"
            tar -xzf "$stage/archive.tgz" -C "$stage"
            """
            return """
            set -eu
            umask 077
            destination="$HOME"/\(quote(destinationPath))
            mkdir -p "$(dirname "$destination")"
            stage=$(mktemp -d "$(dirname "$destination")/.install-XXXXXX")
            trap 'rm -rf "$stage"' EXIT
            \(stage)
            chmod 755 "$stage/package/bin/opencode"
            \(verifyScript("\"$stage/package/bin/opencode\"", version: version))
            mv "$stage/package/bin/opencode" "$destination"

            """
        }
    }

    public static func latestBeta(using transport: any HTTPTransport) async throws(RemoteCLIFailure) -> String {
        let url = "https://registry.npmjs.org/@opencode%2fcli/beta"
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(method: "GET", url: url))
        } catch {
            throw RemoteCLIFailure(code: .install, detail: url)
        }
        guard (200..<300).contains(response.head.statusCode) else {
            throw RemoteCLIFailure(code: .install, detail: url)
        }
        struct BetaMetadata: Decodable {
            let version: String
        }
        guard let decoded = try? JSONDecoder().decode(BetaMetadata.self, from: Data(response.body)),
              isValidBetaVersion(decoded.version)
        else {
            throw RemoteCLIFailure(code: .install, detail: url)
        }
        return decoded.version
    }

    private static func verifyScript(_ command: String, version: String) -> String {
        "test \"$(\(command) --version | awk '{print $NF}' | sed 's/^v//')\" = \(quote(version))"
    }

    private static func isValidVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, first >= 0x30 && first <= 0x39 else { return false }
        for byte in bytes {
            let ok = (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x2B || byte == 0x2D
            if !ok { return false }
        }
        return true
    }

    public static func isValidBetaVersion(_ value: String) -> Bool {
        let prefix = "0.0.0-beta-"
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        guard !suffix.isEmpty else { return false }
        let parts = suffix.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
        }
    }
}

// MARK: - SSH Target Parser & Command Builder (`ssh/command.ts`)

public struct SSHFailure: Error, Equatable, Hashable, Sendable {
    public let code: SSHError
    public let detail: String

    public init(code: SSHError, detail: String = "") {
        self.code = code
        self.detail = detail
    }

    public static func from(_ failure: RemoteCLIFailure) -> SSHFailure {
        let mapped: SSHError
        switch failure.code {
        case .platform: mapped = .platform
        case .version: mapped = .version
        case .install: mapped = .install
        }
        return SSHFailure(code: mapped, detail: failure.detail)
    }
}

public struct ParsedSSHTarget: Equatable, Hashable, Sendable {
    public let host: String
    public let args: [String]

    public init(host: String, args: [String]) {
        self.host = host
        self.args = args
    }
}

public enum SSHCommand {
    private static let standaloneFlags: Set<String> = ["-4", "-6", "-C", "-A", "-a"]
    private static let valueFlags: Set<String> = ["-p", "-l", "-i", "-F", "-J", "-o"]
    private static let allowedOptions: Set<String> = [
        "hostname",
        "user",
        "port",
        "identityfile",
        "identityagent",
        "identitiesonly",
        "proxyjump",
        "proxycommand",
        "connecttimeout",
        "addressfamily",
    ]

    public static func quote(_ value: String) -> String {
        RemoteCLI.quote(value)
    }

    /// Parses and validates an SSH command/target string with shell quoting, allow-listed options, and hostname checks.
    public static func parseTarget(_ input: String) throws(SSHFailure) -> ParsedSSHTarget {
        var tokens: [String] = []
        var word = ""
        var quoteChar: Character?
        var started = false

        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\n" || c == "\r" || c == "\0" {
                throw SSHFailure(code: .input)
            }

            if c == "\\" && quoteChar != "'" && i + 1 < chars.count {
                let next = chars[i + 1]
                if next.isWhitespace || next == "\\" || next == "\"" || next == "'" {
                    word.append(next)
                    started = true
                    i += 2
                    continue
                }
            }

            if let activeQuote = quoteChar {
                if c == activeQuote {
                    quoteChar = nil
                } else {
                    word.append(c)
                }
                i += 1
                continue
            }

            if c == "'" || c == "\"" {
                quoteChar = c
                started = true
                i += 1
                continue
            }

            if c.isWhitespace {
                if started {
                    tokens.append(word)
                }
                word = ""
                started = false
                i += 1
                continue
            }

            word.append(c)
            started = true
            i += 1
        }

        if quoteChar != nil {
            throw SSHFailure(code: .input)
        }
        if started {
            tokens.append(word)
        }

        if tokens.first == "ssh" {
            tokens.removeFirst()
        }

        var args: [String] = []
        var cursor = 0
        while cursor < tokens.count, tokens[cursor].hasPrefix("-") {
            let token = tokens[cursor]
            cursor += 1

            if standaloneFlags.contains(token) {
                args.append(token)
                continue
            }

            guard token.count >= 2 else {
                throw SSHFailure(code: .input)
            }
            let flag = String(token.prefix(2))
            guard valueFlags.contains(flag) else {
                throw SSHFailure(code: .input)
            }

            let value: String
            if token.count > 2 {
                value = String(token.dropFirst(2))
            } else {
                guard cursor < tokens.count else {
                    throw SSHFailure(code: .input)
                }
                value = tokens[cursor]
                cursor += 1
            }

            if value.isEmpty || value.hasPrefix("-") {
                throw SSHFailure(code: .input)
            }

            if flag == "-p" {
                guard value.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                      let port = Int(value),
                      port >= 1 && port <= 65535
                else {
                    throw SSHFailure(code: .input)
                }
            }

            if flag == "-o" {
                let optionKey = value
                    .split(maxSplits: 1, whereSeparator: { $0 == "=" || $0.isWhitespace })
                    .first
                    .map { String($0).lowercased() } ?? ""
                guard allowedOptions.contains(optionKey) else {
                    throw SSHFailure(code: .input)
                }
            }

            args.append(flag)
            args.append(value)
        }

        let remaining = tokens[cursor...]
        guard remaining.count == 1, let host = remaining.first, !host.isEmpty else {
            throw SSHFailure(code: .input)
        }
        guard !host.hasPrefix("-"), isValidHostToken(host) else {
            throw SSHFailure(code: .input)
        }
        if let atIndex = host.lastIndex(of: "@") {
            let userPart = host[..<atIndex]
            if userPart.contains(":") {
                throw SSHFailure(code: .input)
            }
        }

        return ParsedSSHTarget(host: host, args: args)
    }

    public static func executable(for os: GUIPluginOS = .current) -> String {
        os == .windows ? "ssh.exe" : "ssh"
    }

    public static func sshArgs(for target: ParsedSSHTarget) -> [String] {
        [
            "-T",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "RemoteCommand=none",
            "-o", "RequestTTY=no",
            "-o", "PermitLocalCommand=no",
        ] + target.args
    }

    public static func tunnelArgs(
        for target: ParsedSSHTarget,
        localPort: Int,
        remoteHost: String,
        remotePort: Int
    ) -> [String] {
        [
            "-o", "ControlMaster=no",
            "-o", "ControlPersist=no",
        ] + sshArgs(for: target) + [
            "-o", "ExitOnForwardFailure=yes",
            "-L", "127.0.0.1:\(localPort):\(remoteHost):\(remotePort)",
            target.host,
            "sh -c 'exec cat >/dev/null'",
        ]
    }

    /// Formats SSH process failure output while redacting any `OPENCODE_SSH_REGISTRATION_BEGIN...END` private block.
    public static func commandFailureDetail(exitCode: Int?, stdout rawStdout: String, stderr rawStderr: String) -> String {
        let strippedStdout = stripRegistrationBlocks(rawStdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let strippedStderr = rawStderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [strippedStderr, strippedStdout].filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: "\n")
        }
        if let exitCode {
            return "{\"exitCode\":\(exitCode)}"
        }
        return "{\"exitCode\":null}"
    }

    private static func isValidHostToken(_ host: String) -> Bool {
        for byte in host.utf8 {
            let ok = (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x5F || byte == 0x40 || byte == 0x2E
                || byte == 0x3A || byte == 0x5B || byte == 0x5D
                || byte == 0x25 || byte == 0x2D
            if !ok { return false }
        }
        return true
    }

    private static func stripRegistrationBlocks(_ value: String) -> String {
        let beginMarker = "OPENCODE_SSH_REGISTRATION_BEGIN"
        let endMarker = "OPENCODE_SSH_REGISTRATION_END"
        var remaining = value
        while let beginRange = remaining.range(of: beginMarker) {
            if let endRange = remaining.range(of: endMarker, range: beginRange.upperBound..<remaining.endIndex) {
                remaining.removeSubrange(beginRange.lowerBound..<endRange.upperBound)
            } else {
                remaining.removeSubrange(beginRange.lowerBound..<remaining.endIndex)
            }
        }
        return remaining
    }
}

// MARK: - SSH Askpass Protocol (`ssh/askpass.ts`)

public struct SSHAskpassRequest: Equatable, Hashable, Sendable, Codable {
    public let token: String
    public let text: String
    public let confirm: Bool

    public init(token: String, text: String, confirm: Bool) {
        self.token = token
        self.text = text
        self.confirm = confirm
    }
}

public struct SSHAskpassResponse: Equatable, Hashable, Sendable, Codable {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

public enum SSHAskpassProtocol {
    public static let maxRequestLength = 16_384

    /// Decodes a single newline-terminated askpass JSON request and verifies its length and token.
    public static func decodeRequest(_ line: String, expectedToken: String) throws(SSHFailure) -> SSHAskpassRequest {
        if line.utf8.count > maxRequestLength {
            throw SSHFailure(code: .connection)
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let request = try? JSONDecoder().decode(SSHAskpassRequest.self, from: data)
        else {
            throw SSHFailure(code: .connection)
        }
        guard request.token == expectedToken else {
            throw SSHFailure(code: .connection)
        }
        return request
    }

    /// Encodes the askpass response payload sent back to the askpass helper over loopback TCP.
    public static func encodeResponse(_ value: String) throws(SSHFailure) -> String {
        guard let data = try? JSONEncoder().encode(SSHAskpassResponse(value: value)),
              let encoded = String(data: data, encoding: .utf8)
        else {
            throw SSHFailure(code: .connection)
        }
        return encoded
    }

    /// Builds the environment dictionary passed to `ssh` for askpass helper mediation.
    public static func environment(
        binary: String,
        port: Int,
        token: String,
        existingDisplay: String? = nil
    ) -> [String: String] {
        let display: String
        if let existingDisplay, !existingDisplay.isEmpty {
            display = existingDisplay
        } else {
            display = "opencode"
        }
        return [
            "SSH_ASKPASS": binary,
            "SSH_ASKPASS_REQUIRE": "force",
            "DISPLAY": display,
            "OPENCODE_SSH_ASKPASS_PORT": String(port),
            "OPENCODE_SSH_ASKPASS_TOKEN": token,
        ]
    }
}

/// Actor coordinating serialized SSH askpass prompts and responses without OS socket coupling.
public actor SSHAskpassCoordinator {
    public let token: String
    private var nextPromptSeq = 0
    private var activePromptID: String?
    private var pendingContinuation: CheckedContinuation<String, any Error>?
    private var queuedRequests: [(SSHAskpassRequest, CheckedContinuation<String, any Error>)] = []
    private let onPrompt: @Sendable (SSHPrompt) async -> Void
    private let onClear: @Sendable (String) async -> Void

    public init(
        token: String,
        onPrompt: @escaping @Sendable (SSHPrompt) async -> Void,
        onClear: @escaping @Sendable (String) async -> Void
    ) {
        self.token = token
        self.onPrompt = onPrompt
        self.onClear = onClear
    }

    /// Handles a raw askpass helper request line, serializing concurrent prompts one at a time.
    public func handleRequestLine(_ line: String) async throws -> String {
        let request = try SSHAskpassProtocol.decodeRequest(line, expectedToken: token)
        let answer: String = try await withCheckedThrowingContinuation { continuation in
            if activePromptID == nil {
                startPrompt(request: request, continuation: continuation)
            } else {
                queuedRequests.append((request, continuation))
            }
        }
        return try SSHAskpassProtocol.encodeResponse(answer)
    }

    /// Answers the currently active prompt if its ID matches.
    public func respond(promptID: String, value: String) async {
        guard activePromptID == promptID, let continuation = pendingContinuation else { return }
        activePromptID = nil
        pendingContinuation = nil
        await onClear(promptID)
        continuation.resume(returning: value)
        dequeueNextIfNeeded()
    }

    /// Cancels all active and queued askpass requests.
    public func cancelAll() async {
        if let id = activePromptID, let continuation = pendingContinuation {
            activePromptID = nil
            pendingContinuation = nil
            await onClear(id)
            continuation.resume(throwing: SSHFailure(code: .connection))
        }
        let queued = queuedRequests
        queuedRequests.removeAll()
        for (_, continuation) in queued {
            continuation.resume(throwing: SSHFailure(code: .connection))
        }
    }

    public func currentPromptID() -> String? {
        activePromptID
    }

    private func startPrompt(request: SSHAskpassRequest, continuation: CheckedContinuation<String, any Error>) {
        nextPromptSeq += 1
        let id = "askpass-\(nextPromptSeq)"
        activePromptID = id
        pendingContinuation = continuation
        let prompt = SSHPrompt(id: id, text: request.text, confirm: request.confirm)
        let callback = onPrompt
        Task {
            await callback(prompt)
        }
    }

    private func dequeueNextIfNeeded() {
        guard activePromptID == nil, !queuedRequests.isEmpty else { return }
        let next = queuedRequests.removeFirst()
        startPrompt(request: next.0, continuation: next.1)
    }
}

// MARK: - SSH Remote Bootstrap (`ssh/bootstrap.ts`)

public struct SSHBootstrapRegistration: Equatable, Hashable, Sendable, Codable {
    public let url: String
    public let password: String
    public let version: String
    public let pid: Int

    public init(url: String, password: String, version: String, pid: Int) {
        self.url = url
        self.password = password
        self.version = version
        self.pid = pid
    }
}

public struct SSHBootstrapAddress: Equatable, Hashable, Sendable {
    public let host: String
    public let port: Int
    public let password: String

    public init(host: String, port: Int, password: String) {
        self.host = host
        self.port = port
        self.password = password
    }
}

public protocol SSHCommandExecutor: Sendable {
    func run(args: [String], env: [String: String], stdin: [UInt8]?) async throws -> String
}

public enum SSHBootstrap {
    private static let registrationScript: String = """
    status=$("$cli" service status) || exit 0
    if [ "$status" = stopped ]; then exit 0; fi
    printf 'OPENCODE_SSH_STATUS=%s\\n' "$status"
    for file in "${XDG_STATE_HOME:-$HOME/.local/state}"/opencode/service*.json; do
      if [ ! -f "$file" ]; then continue; fi
      printf 'OPENCODE_SSH_REGISTRATION_BEGIN\\n'
      cat "$file"
      printf '\\nOPENCODE_SSH_REGISTRATION_END\\n'
    done

    """

    public static let discoverScript: String = {
        let discover = RemoteCLI.discoverScript(
            fromPath: true,
            cache: RemoteCLI.CacheSpec(directory: ".opencode/desktop-ssh", prefix: "0.0.0-beta-")
        )
        return "set -eu\n\(discover)if [ -z \"$cli\" ]; then exit 0; fi\n\(registrationScript)"
    }()

    public static func startScript(version: String, replace: Bool = false) throws(RemoteCLIFailure) -> String {
        let bin = try binaryPath(version: version)
        return """
        set -eu
        cli="\(bin)"
        "$cli" service \(replace ? "restart" : "start")
        \(registrationScript)
        """
    }

    public static func binaryPath(version: String) throws(RemoteCLIFailure) -> String {
        let validated = try RemoteCLI.requireVersion(version)
        return "$HOME/.opencode/desktop-ssh/\(validated)/opencode"
    }

    /// Parses the last `OPENCODE_SSH_STATUS=<url>` and matching `OPENCODE_SSH_REGISTRATION_BEGIN..END` JSON block.
    public static func parseRegistration(_ output: String) -> SSHBootstrapRegistration? {
        let lines = output.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
        let prefix = "OPENCODE_SSH_STATUS="
        guard let statusLine = lines.last(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        let status = String(statusLine.dropFirst(prefix.count))
        guard !status.isEmpty else { return nil }

        let beginMarker = "OPENCODE_SSH_REGISTRATION_BEGIN"
        let endMarker = "OPENCODE_SSH_REGISTRATION_END"
        var searchStart = output.startIndex
        while let beginRange = output.range(of: beginMarker, range: searchStart..<output.endIndex) {
            var payloadStart = beginRange.upperBound
            if payloadStart < output.endIndex && output[payloadStart] == "\r" {
                payloadStart = output.index(after: payloadStart)
            }
            if payloadStart < output.endIndex && output[payloadStart] == "\n" {
                payloadStart = output.index(after: payloadStart)
            }
            guard let endRange = output.range(of: endMarker, range: payloadStart..<output.endIndex) else {
                break
            }
            var payloadEnd = endRange.lowerBound
            if payloadEnd > payloadStart {
                let prev = output.index(before: payloadEnd)
                if output[prev] == "\n" {
                    payloadEnd = prev
                    if payloadEnd > payloadStart {
                        let prev2 = output.index(before: payloadEnd)
                        if output[prev2] == "\r" {
                            payloadEnd = prev2
                        }
                    }
                }
            }
            let jsonSlice = String(output[payloadStart..<payloadEnd])
            if let data = jsonSlice.data(using: .utf8),
               let registration = try? JSONDecoder().decode(SSHBootstrapRegistration.self, from: data),
               registration.pid > 0,
               registration.url == status
            {
                return registration
            }
            searchStart = endRange.upperBound
        }
        return nil
    }

    /// Validates that a remote registration URL is a loopback HTTP address and normalizes it for SSH forwarding.
    public static func connectionAddress(urlString: String, password: String) throws(SSHFailure) -> SSHBootstrapAddress {
        guard let components = URLComponents(string: urlString),
              components.scheme?.lowercased() == "http",
              let rawHost = components.host
        else {
            throw SSHFailure(code: .service)
        }
        let normalizedHost = rawHost.lowercased()
        let allowed: Set<String> = ["127.0.0.1", "localhost", "0.0.0.0", "::", "::1", "[::]", "[::1]"]
        guard allowed.contains(normalizedHost) else {
            throw SSHFailure(code: .service)
        }
        let isIPv6Loopback = normalizedHost == "::1" || normalizedHost == "[::1]"
        return SSHBootstrapAddress(
            host: isIPv6Loopback ? "[::1]" : "127.0.0.1",
            port: components.port ?? 80,
            password: password
        )
    }

    /// Executes the full remote discovery -> stage/install (with HTTP archive upload fallback) -> service start flow.
    public static func run(
        target: ParsedSSHTarget,
        version requestedVersion: String,
        development: Bool = false,
        env: [String: String] = [:],
        replace: Bool = false,
        executor: any SSHCommandExecutor,
        httpTransport: any HTTPTransport
    ) async throws(SSHFailure) -> SSHBootstrapAddress {
        func runScript(_ script: String) async throws(SSHFailure) -> String {
            do {
                return try await executor.run(
                    args: SSHCommand.sshArgs(for: target) + [target.host, "sh -l -s"],
                    env: env,
                    stdin: Array(script.utf8)
                )
            } catch let err as SSHFailure {
                throw err
            } catch let err as RemoteCLIFailure {
                throw SSHFailure.from(err)
            } catch {
                throw SSHFailure(code: .connection, detail: String(describing: error))
            }
        }

        let discoveredOutput = try await runScript(discoverScript)
        if let registered = parseRegistration(discoveredOutput) {
            if development || registered.version == requestedVersion {
                return try connectionAddress(urlString: registered.url, password: registered.password)
            }
            if !replace {
                throw SSHFailure(code: .version, detail: registered.version)
            }
        }

        let destination: String
        do {
            destination = try binaryPath(version: requestedVersion)
        } catch {
            throw SSHFailure.from(error)
        }

        let existingOutput = try await runScript(RemoteCLI.versionScript("\"\(destination)\""))
        let existingVersion = try? RemoteCLI.parseVersion(existingOutput)
        let staged = existingVersion == requestedVersion

        let version: String
        if development && !staged {
            do {
                version = try await RemoteCLI.latestBeta(using: httpTransport)
            } catch {
                throw SSHFailure.from(error)
            }
        } else {
            version = requestedVersion
        }

        let installDirectory = ".opencode/desktop-ssh/\(version)"

        if !staged {
            let probeOutput: String
            do {
                probeOutput = try await runScript(RemoteCLI.probeScript)
            } catch {
                throw SSHFailure(code: .platform)
            }

            let probeTarget = probeOutput
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .last(where: { $0.hasPrefix("OPENCODE_REMOTE_TARGET=") })
                .map { String($0.dropFirst("OPENCODE_REMOTE_TARGET=".count)) } ?? ""

            let archiveURL: String
            let downloadScript: String
            let uploadScript: String
            do {
                archiveURL = try RemoteCLI.archiveUrl(target: probeTarget, version: version)
                downloadScript = try RemoteCLI.installScript(
                    version: version,
                    directory: installDirectory,
                    source: .download(url: archiveURL)
                )
                uploadScript = try RemoteCLI.installScript(
                    version: version,
                    directory: installDirectory,
                    source: .archive
                )
            } catch {
                throw SSHFailure.from(error)
            }

            do {
                _ = try await runScript(downloadScript)
            } catch let downloadError {
                let response: HTTPResponse
                do {
                    response = try await httpTransport.send(HTTPRequest(method: "GET", url: archiveURL))
                } catch {
                    throw SSHFailure(code: .connection, detail: String(describing: error))
                }
                guard (200..<300).contains(response.head.statusCode) else {
                    let code: SSHError = response.head.statusCode == 404 ? .unpublished : .install
                    throw SSHFailure(
                        code: code,
                        detail: "{\"version\":\"\(version)\",\"target\":\"\(probeTarget)\",\"url\":\"\(archiveURL)\",\"status\":\(response.head.statusCode)}"
                    )
                }
                do {
                    _ = try await executor.run(
                        args: SSHCommand.sshArgs(for: target) + [
                            target.host,
                            "sh -c \(SSHCommand.quote(uploadScript))",
                        ],
                        env: env,
                        stdin: response.body
                    )
                } catch {
                    throw SSHFailure(code: .install, detail: downloadError.detail)
                }
            }
        }

        let startCmd: String
        do {
            startCmd = try startScript(version: version, replace: replace)
        } catch {
            throw SSHFailure.from(error)
        }
        let startOutput = try await runScript(startCmd)
        guard let registration = parseRegistration(startOutput) else {
            throw SSHFailure(code: .service)
        }
        if !development && registration.version != requestedVersion {
            throw SSHFailure(code: .version, detail: registration.version)
        }
        return try connectionAddress(urlString: registration.url, password: registration.password)
    }
}

// MARK: - SSH Add Dialog Load Machine (`ssh/add-machine.ts`)

public enum SSHAddMachine {
    public static let dialogLoadTimeoutMs = 15_000

    public enum State: Equatable, Sendable {
        case idle(issued: Int)
        case loading(attempt: Int, openProject: Bool)
        case disposed
    }

    public enum Event<Module: Sendable>: Sendable {
        case addRequested(openProject: Bool)
        case addLoaded(attempt: Int, module: Module)
        case addFailed(attempt: Int, error: String)
        case disposed
    }

    public enum Effect<Module: Sendable>: Sendable {
        case load(attempt: Int)
        case open(module: Module, openProject: Bool)
        case toastFailed(error: String)
    }

    public static let initialState: State = .idle(issued: 0)

    public static func reduce<Module: Sendable>(
        state: State,
        event: Event<Module>
    ) -> GUIStateTransition<State, Effect<Module>> {
        if state == .disposed {
            return GUIStateTransition(state: state)
        }
        switch event {
        case .disposed:
            return GUIStateTransition(state: .disposed)

        case .addRequested(let openProject):
            switch state {
            case .loading(let attempt, let currentOpenProject):
                if openProject && !currentOpenProject {
                    return GUIStateTransition(state: .loading(attempt: attempt, openProject: true))
                }
                return GUIStateTransition(state: state)
            case .idle(let issued):
                let attempt = issued + 1
                return GUIStateTransition(
                    state: .loading(attempt: attempt, openProject: openProject),
                    effects: [.load(attempt: attempt)]
                )
            case .disposed:
                return GUIStateTransition(state: state)
            }

        case .addLoaded(let attempt, let module):
            guard case .loading(let currentAttempt, let openProject) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .idle(issued: currentAttempt),
                effects: [.open(module: module, openProject: openProject)]
            )

        case .addFailed(let attempt, let error):
            guard case .loading(let currentAttempt, _) = state, currentAttempt == attempt else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: .idle(issued: currentAttempt),
                effects: [.toastFailed(error: error)]
            )
        }
    }
}

extension SSHAddMachine.Event: Equatable where Module: Equatable {}
extension SSHAddMachine.Effect: Equatable where Module: Equatable {}

// MARK: - SSH Dialog Machine (`ssh/dialog-machine.ts`)

public enum SSHDialogMachine: GUIStateMachine {
    public enum Mode: String, Equatable, Hashable, Sendable, Codable {
        case add
        case connect
        case prompt
    }

    public struct Challenge: Equatable, Hashable, Sendable {
        public let prompt: SSHPrompt
        public let response: String

        public init(prompt: SSHPrompt, response: String) {
            self.prompt = prompt
            self.response = response
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public let item: SSHItem?
        public let submitting: Bool
        public let error: Bool
        public let answeredPrompt: String?
        public let activeAttempt: Bool

        public init(
            item: SSHItem? = nil,
            submitting: Bool = false,
            error: Bool = false,
            answeredPrompt: String? = nil,
            activeAttempt: Bool = false
        ) {
            self.item = item
            self.submitting = submitting
            self.error = error
            self.answeredPrompt = answeredPrompt
            self.activeAttempt = activeAttempt
        }
    }

    public enum Status: Equatable, Sendable {
        case idle
        case active(prompted: Bool, challenge: Challenge?)
        case completed(prompted: Bool, challenge: Challenge?)
        case closed
    }

    public struct State: Equatable, Sendable {
        public let id: String
        public let mode: Mode
        public let target: String
        public let name: String
        public let status: Status

        public init(id: String, mode: Mode, target: String, name: String, status: Status) {
            self.id = id
            self.mode = mode
            self.target = target
            self.name = name
            self.status = status
        }
    }

    public enum Event: Equatable, Sendable {
        case targetChanged(String)
        case nameChanged(String)
        case responseChanged(prompt: String, value: String)
        case submitted(snapshot: Snapshot)
        case responded(snapshot: Snapshot)
        case synced(snapshot: Snapshot)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case connect(config: SSHConfig, replace: Bool)
        case respond(prompt: String, value: String)
        case cancel
        case complete
    }

    public enum ErrorKey: Equatable, Hashable, Sendable {
        case requestFailed
        case ssh(SSHError)

        public var rawKey: String {
            switch self {
            case .requestFailed: return "common.requestFailed"
            case .ssh(let error): return "error.\(error.rawValue)"
            }
        }
    }

    public enum TitleKey: String, Equatable, Hashable, Sendable {
        case add
        case connectTo
    }

    public enum PrimaryAction: String, Equatable, Hashable, Sendable {
        case submit
        case respond
    }

    public enum PrimaryLabel: String, Equatable, Hashable, Sendable {
        case connecting = "stage.connecting"
        case update
        case connect
        case formAdd = "form.add"
        case trust
        case `continue`
    }

    public struct PrimaryButton: Equatable, Sendable {
        public let action: PrimaryAction
        public let disabled: Bool
        public let label: PrimaryLabel

        public init(action: PrimaryAction, disabled: Bool, label: PrimaryLabel) {
            self.action = action
            self.disabled = disabled
            self.label = label
        }
    }

    public struct View: Equatable, Sendable {
        public let title: TitleKey
        public let showForm: Bool
        public let inputsDisabled: Bool
        public let incompatible: Bool
        public let prompt: SSHPrompt?
        public let response: String
        public let waiting: Bool
        public let error: ErrorKey?
        public let primary: PrimaryButton

        public init(
            title: TitleKey,
            showForm: Bool,
            inputsDisabled: Bool,
            incompatible: Bool,
            prompt: SSHPrompt?,
            response: String,
            waiting: Bool,
            error: ErrorKey?,
            primary: PrimaryButton
        ) {
            self.title = title
            self.showForm = showForm
            self.inputsDisabled = inputsDisabled
            self.incompatible = incompatible
            self.prompt = prompt
            self.response = response
            self.waiting = waiting
            self.error = error
            self.primary = primary
        }
    }

    public static func createState(id: String, config: SSHConfig? = nil, promptOnly: Bool = false) -> State {
        let target = config?.target ?? ""
        let name = config?.name ?? ""
        if promptOnly {
            return State(id: id, mode: .prompt, target: target, name: name, status: .active(prompted: true, challenge: nil))
        }
        return State(id: id, mode: config != nil ? .connect : .add, target: target, name: name, status: .idle)
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        switch state.status {
        case .completed, .closed:
            return GUIStateTransition(state: state)
        case .idle, .active:
            break
        }

        switch event {
        case .disposed:
            let wasActive: Bool
            if case .active = state.status { wasActive = true } else { wasActive = false }
            let next = State(id: state.id, mode: state.mode, target: state.target, name: state.name, status: .closed)
            return GUIStateTransition(state: next, effects: wasActive ? [.cancel] : [])

        case .targetChanged(let value):
            if state.target == value { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: State(id: state.id, mode: state.mode, target: value, name: state.name, status: state.status)
            )

        case .nameChanged(let value):
            if state.name == value { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: State(id: state.id, mode: state.mode, target: state.target, name: value, status: state.status)
            )

        case .submitted(let snapshot):
            let hasChallenge: Bool
            if case .active(_, let challenge) = state.status, challenge != nil {
                hasChallenge = true
            } else {
                hasChallenge = false
            }
            if isBusy(state, snapshot) || state.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasChallenge {
                return GUIStateTransition(state: state)
            }
            let next = State(
                id: state.id,
                mode: state.mode,
                target: state.target,
                name: state.name,
                status: .active(prompted: false, challenge: nil)
            )
            return GUIStateTransition(
                state: next,
                effects: [
                    .connect(
                        config: SSHConfig(id: state.id, target: state.target, name: state.name),
                        replace: snapshot.item?.stage == .incompatible
                    ),
                ]
            )

        case .responseChanged(let prompt, let value):
            guard case .active(let prompted, let challenge?) = state.status,
                  challenge.prompt.id == prompt,
                  challenge.response != value
            else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: State(
                    id: state.id,
                    mode: state.mode,
                    target: state.target,
                    name: state.name,
                    status: .active(prompted: prompted, challenge: Challenge(prompt: challenge.prompt, response: value))
                )
            )

        case .responded(let snapshot):
            guard case .active(_, let challenge?) = state.status,
                  snapshot.item?.prompt?.id == challenge.prompt.id,
                  !isWaiting(state, snapshot),
                  challenge.prompt.confirm || !challenge.response.isEmpty
            else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: state,
                effects: [.respond(prompt: challenge.prompt.id, value: challenge.prompt.confirm ? "yes" : challenge.response)]
            )

        case .synced(let snapshot):
            guard case .active(let prompted, let challenge) = state.status else {
                return GUIStateTransition(state: state)
            }
            if !snapshot.submitting && snapshot.item?.stage == .ready {
                return GUIStateTransition(
                    state: State(
                        id: state.id,
                        mode: state.mode,
                        target: state.target,
                        name: state.name,
                        status: .completed(prompted: prompted, challenge: challenge)
                    ),
                    effects: [.complete]
                )
            }
            if let prompt = snapshot.item?.prompt {
                if challenge?.prompt.id == prompt.id {
                    return GUIStateTransition(state: state)
                }
                return GUIStateTransition(
                    state: State(
                        id: state.id,
                        mode: state.mode,
                        target: state.target,
                        name: state.name,
                        status: .active(prompted: true, challenge: Challenge(prompt: prompt, response: ""))
                    )
                )
            }
            if challenge == nil
                || (snapshot.answeredPrompt == challenge?.prompt.id
                    && !snapshot.error
                    && (snapshot.submitting || snapshot.item?.stage == .connecting))
            {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: State(
                    id: state.id,
                    mode: state.mode,
                    target: state.target,
                    name: state.name,
                    status: .active(prompted: prompted, challenge: nil)
                )
            )
        }
    }

    public static func view(state: State, snapshot: Snapshot) -> View {
        let prompted: Bool
        let challenge: Challenge?
        let settled: Bool
        switch state.status {
        case .idle:
            prompted = false
            challenge = nil
            settled = false
        case .active(let isPrompted, let activeChallenge):
            prompted = isPrompted
            challenge = activeChallenge
            settled = false
        case .completed(let isPrompted, let completedChallenge):
            prompted = isPrompted
            challenge = completedChallenge
            settled = true
        case .closed:
            prompted = false
            challenge = nil
            settled = true
        }

        let incompatible = snapshot.item?.stage == .incompatible
        let busy = isBusy(state, snapshot)
        let waiting = isWaiting(state, snapshot) || settled

        let isActive: Bool
        if case .active = state.status { isActive = true } else { isActive = false }
        let lost = isActive && !snapshot.submitting && !snapshot.activeAttempt && snapshot.item == nil && !snapshot.error

        let rawError: ErrorKey?
        if snapshot.error || lost {
            rawError = .requestFailed
        } else if let itemError = snapshot.item?.error {
            rawError = .ssh(itemError)
        } else {
            rawError = nil
        }

        let primary: PrimaryButton
        if let challenge {
            primary = PrimaryButton(
                action: .respond,
                disabled: waiting || (!challenge.prompt.confirm && challenge.response.isEmpty),
                label: waiting ? .connecting : (challenge.prompt.confirm ? .trust : .continue)
            )
        } else {
            let trimmedTarget = state.target.trimmingCharacters(in: .whitespacesAndNewlines)
            let label: PrimaryLabel
            if busy {
                label = .connecting
            } else if incompatible {
                label = .update
            } else if state.mode == .add {
                label = .formAdd
            } else {
                label = .connect
            }
            primary = PrimaryButton(
                action: .submit,
                disabled: busy || trimmedTarget.isEmpty || settled,
                label: label
            )
        }

        return View(
            title: (prompted || state.mode != .add) ? .connectTo : .add,
            showForm: state.mode != .prompt && !incompatible && (!prompted || (rawError != nil && challenge == nil)),
            inputsDisabled: busy || challenge != nil || settled,
            incompatible: incompatible,
            prompt: challenge?.prompt,
            response: challenge?.response ?? "",
            waiting: waiting,
            error: incompatible ? nil : rawError,
            primary: primary
        )
    }

    private static func isBusy(_ state: State, _ snapshot: Snapshot) -> Bool {
        if snapshot.submitting { return true }
        guard case .active = state.status else { return false }
        return snapshot.activeAttempt && !snapshot.error && (snapshot.item?.stage ?? .connecting) == .connecting
    }

    private static func isWaiting(_ state: State, _ snapshot: Snapshot) -> Bool {
        if isBusy(state, snapshot) { return true }
        guard case .active(_, let challenge?) = state.status else { return false }
        return !snapshot.error && snapshot.answeredPrompt == challenge.prompt.id
    }
}

// MARK: - SSH Main Process Machine (`ssh/main-machine.ts`)

public enum SSHMainMachine: GUIStateMachine {
    public static let retryLimit = 5
    public static let retryDelayMs = 3_000

    public enum Resting: Equatable, Sendable {
        case disconnected
        case authentication
        case incompatible(detail: String)
        case failed(code: SSHError, detail: String, failures: Int)
    }

    public enum ServerPhase: Equatable, Sendable {
        case disconnected
        case authentication
        case incompatible(detail: String)
        case connecting(attempt: Int, owner: Int?, failures: Int, resting: Resting)
        case authenticating(attempt: Int, owner: Int, failures: Int, resting: Resting, prompt: SSHPrompt)
        case ready(attempt: Int, http: SSHHttp)
        case failed(code: SSHError, detail: String, failures: Int, retryAttempt: Int?)

        public var isActive: Bool {
            switch self {
            case .connecting, .authenticating: return true
            default: return false
            }
        }
    }

    public struct ServerRecord: Equatable, Sendable {
        public let config: SSHConfig
        public let savedConfig: SSHConfig?
        public let destination: String?
        public let phase: ServerPhase
        public let waiters: [Int]

        public init(
            config: SSHConfig,
            savedConfig: SSHConfig? = nil,
            destination: String? = nil,
            phase: ServerPhase = .disconnected,
            waiters: [Int] = []
        ) {
            self.config = config
            self.savedConfig = savedConfig
            self.destination = destination
            self.phase = phase
            self.waiters = waiters
        }
    }

    public enum LifecycleStatus: String, Equatable, Sendable {
        case open
        case closed
    }

    public struct State: Equatable, Sendable {
        public let status: LifecycleStatus
        public let issued: Int
        public let servers: [ServerRecord]

        public init(status: LifecycleStatus, issued: Int, servers: [ServerRecord]) {
            self.status = status
            self.issued = issued
            self.servers = servers
        }
    }

    public enum Event: Equatable, Sendable {
        case start(request: SSHStart, owner: Int?)
        case destinationResolved(id: String, attempt: Int, destination: String)
        case promptReceived(id: String, attempt: Int, prompt: SSHPrompt)
        case promptCleared(id: String, attempt: Int, promptID: String)
        case respond(id: String, promptID: String, value: String, owner: Int)
        case attemptReady(id: String, attempt: Int, http: SSHHttp)
        case attemptFailed(id: String, attempt: Int, code: SSHError, detail: String)
        case retryDue(id: String, attempt: Int)
        case resolveRequested(id: String, waiter: Int)
        case resolveAborted(id: String, waiter: Int)
        case healthProbed(id: String, attempt: Int, waiter: Int, healthy: Bool)
        case cancel(id: String, owner: Int)
        case forget(id: String)
        case windowDetached(owner: Int)
        case close
    }

    public enum Effect: Equatable, Sendable {
        case attemptStart(id: String, attempt: Int, config: SSHConfig, replace: Bool)
        case attemptStop(attempt: Int)
        case attemptRespond(attempt: Int, promptID: String, value: String)
        case retrySchedule(id: String, attempt: Int, delayMs: Int)
        case retryCancel(attempt: Int)
        case healthProbe(id: String, attempt: Int, http: SSHHttp, waiter: Int)
        case waitersResolve(waiters: [Int], http: SSHHttp?)
        case configsSave(configs: [SSHConfig])
    }

    public static func createState(configs: [SSHConfig] = []) -> State {
        State(
            status: .open,
            issued: 0,
            servers: configs.map { ServerRecord(config: $0, savedConfig: $0, phase: .disconnected, waiters: []) }
        )
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if state.status == .closed {
            if case .resolveRequested(_, let waiter) = event {
                return GUIStateTransition(state: state, effects: [.waitersResolve(waiters: [waiter], http: nil)])
            }
            return GUIStateTransition(state: state)
        }

        switch event {
        case .start(let request, let owner):
            return handleStart(state: state, request: request, owner: owner)

        case .close:
            return handleClose(state: state)

        case .windowDetached(let owner):
            var current = state
            var effects: [Effect] = []
            for server in state.servers {
                let step = handleCancel(state: current, id: server.config.id, owner: owner)
                current = step.state
                effects.append(contentsOf: step.effects)
            }
            return GUIStateTransition(state: current, effects: effects)

        case .cancel(let id, let owner):
            return handleCancel(state: state, id: id, owner: owner)

        case .forget(let id):
            guard let server = state.servers.first(where: { $0.config.id == id }) else {
                return GUIStateTransition(state: state)
            }
            let remaining = state.servers.filter { $0.config.id != id }
            var effects = haltEffects(for: server.phase)
            effects.append(contentsOf: releaseEffects(waiters: server.waiters))
            if server.savedConfig != nil {
                effects.append(saveEffect(servers: remaining))
            }
            return GUIStateTransition(
                state: State(status: state.status, issued: state.issued, servers: remaining),
                effects: effects
            )

        case .resolveRequested(let id, let waiter):
            guard let server = state.servers.first(where: { $0.config.id == id }) else {
                return GUIStateTransition(state: state, effects: [.waitersResolve(waiters: [waiter], http: nil)])
            }
            switch server.phase {
            case .ready(let attempt, let http):
                let updated = ServerRecord(
                    config: server.config,
                    savedConfig: server.savedConfig,
                    destination: server.destination,
                    phase: server.phase,
                    waiters: server.waiters + [waiter]
                )
                return GUIStateTransition(
                    state: put(state, updated),
                    effects: [.healthProbe(id: id, attempt: attempt, http: http, waiter: waiter)]
                )
            case .connecting, .authenticating:
                let updated = ServerRecord(
                    config: server.config,
                    savedConfig: server.savedConfig,
                    destination: server.destination,
                    phase: server.phase,
                    waiters: server.waiters + [waiter]
                )
                return GUIStateTransition(state: put(state, updated))
            case .failed(_, _, _, let retryAttempt) where retryAttempt != nil:
                let updated = ServerRecord(
                    config: server.config,
                    savedConfig: server.savedConfig,
                    destination: server.destination,
                    phase: server.phase,
                    waiters: server.waiters + [waiter]
                )
                return GUIStateTransition(state: put(state, updated))
            default:
                return GUIStateTransition(state: state, effects: [.waitersResolve(waiters: [waiter], http: nil)])
            }

        case .resolveAborted(let id, let waiter):
            guard let server = state.servers.first(where: { $0.config.id == id }),
                  server.waiters.contains(waiter)
            else {
                return GUIStateTransition(state: state)
            }
            let updated = ServerRecord(
                config: server.config,
                savedConfig: server.savedConfig,
                destination: server.destination,
                phase: server.phase,
                waiters: server.waiters.filter { $0 != waiter }
            )
            return GUIStateTransition(state: put(state, updated))

        case .healthProbed(let id, let probedAttempt, let waiter, let healthy):
            guard let server = state.servers.first(where: { $0.config.id == id }),
                  server.waiters.contains(waiter),
                  case .ready(let currentAttempt, let http) = server.phase
            else {
                return GUIStateTransition(state: state)
            }
            if healthy || currentAttempt != probedAttempt {
                let updated = ServerRecord(
                    config: server.config,
                    savedConfig: server.savedConfig,
                    destination: server.destination,
                    phase: server.phase,
                    waiters: server.waiters.filter { $0 != waiter }
                )
                return GUIStateTransition(
                    state: put(state, updated),
                    effects: [.waitersResolve(waiters: [waiter], http: http)]
                )
            }
            let nextAttempt = state.issued + 1
            let updated = ServerRecord(
                config: server.config,
                savedConfig: server.savedConfig,
                destination: server.destination,
                phase: .connecting(attempt: nextAttempt, owner: nil, failures: 0, resting: .disconnected),
                waiters: server.waiters
            )
            return GUIStateTransition(
                state: put(State(status: state.status, issued: nextAttempt, servers: state.servers), updated),
                effects: [
                    .attemptStop(attempt: currentAttempt),
                    .attemptStart(id: id, attempt: nextAttempt, config: server.config, replace: false),
                ]
            )

        case .retryDue(let id, let dueAttempt):
            guard let server = state.servers.first(where: { $0.config.id == id }),
                  case .failed(let code, let detail, let failures, let retryAttempt) = server.phase,
                  retryAttempt == dueAttempt
            else {
                return GUIStateTransition(state: state)
            }
            let nextAttempt = state.issued + 1
            let updated = ServerRecord(
                config: server.config,
                savedConfig: server.savedConfig,
                destination: server.destination,
                phase: .connecting(
                    attempt: nextAttempt,
                    owner: nil,
                    failures: failures,
                    resting: .failed(code: code, detail: detail, failures: failures)
                ),
                waiters: server.waiters
            )
            return GUIStateTransition(
                state: put(State(status: state.status, issued: nextAttempt, servers: state.servers), updated),
                effects: [.attemptStart(id: id, attempt: nextAttempt, config: server.config, replace: false)]
            )

        case .respond(let id, let promptID, let value, let owner):
            guard let server = state.servers.first(where: { $0.config.id == id }),
                  case .authenticating(let attempt, let phaseOwner, _, _, let prompt) = server.phase,
                  phaseOwner == owner,
                  prompt.id == promptID
            else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: state,
                effects: [.attemptRespond(attempt: attempt, promptID: promptID, value: value)]
            )

        case .attemptFailed(let id, let failedAttempt, let code, let detail):
            guard let server = state.servers.first(where: { $0.config.id == id }) else {
                return GUIStateTransition(state: state)
            }
            let priorFailures: Int
            switch server.phase {
            case .connecting(let attempt, _, let failures, _) where attempt == failedAttempt:
                priorFailures = failures
            case .authenticating(let attempt, _, let failures, _, _) where attempt == failedAttempt:
                priorFailures = failures
            case .ready(let attempt, _) where attempt == failedAttempt:
                priorFailures = 0
            default:
                return GUIStateTransition(state: state)
            }
            return handleFailed(state: state, server: server, reported: code, detail: detail, failures: priorFailures + 1)

        case .destinationResolved(let id, let targetAttempt, let destination):
            guard let server = state.servers.first(where: { $0.config.id == id }),
                  activeAttempt(of: server.phase) == targetAttempt
            else {
                return GUIStateTransition(state: state)
            }
            let updated = ServerRecord(
                config: server.config,
                savedConfig: server.savedConfig,
                destination: destination,
                phase: server.phase,
                waiters: server.waiters
            )
            return GUIStateTransition(state: put(state, updated))

        case .promptReceived(let id, let targetAttempt, let prompt):
            guard let server = state.servers.first(where: { $0.config.id == id }) else {
                return GUIStateTransition(state: state)
            }
            switch server.phase {
            case .connecting(let attempt, let owner, let failures, let resting) where attempt == targetAttempt:
                guard let owner else {
                    let updated = ServerRecord(
                        config: server.config,
                        savedConfig: server.savedConfig,
                        destination: server.destination,
                        phase: .authentication,
                        waiters: []
                    )
                    return GUIStateTransition(
                        state: put(state, updated),
                        effects: [.attemptStop(attempt: attempt)] + releaseEffects(waiters: server.waiters)
                    )
                }
                let updated = ServerRecord(
                    config: server.config,
                    savedConfig: server.savedConfig,
                    destination: server.destination,
                    phase: .authenticating(
                        attempt: attempt,
                        owner: owner,
                        failures: failures,
                        resting: resting,
                        prompt: prompt
                    ),
                    waiters: server.waiters
                )
                return GUIStateTransition(state: put(state, updated))

            case .authenticating(let attempt, let owner, let failures, let resting, _) where attempt == targetAttempt:
                let updated = ServerRecord(
                    config: server.config,
                    savedConfig: server.savedConfig,
                    destination: server.destination,
                    phase: .authenticating(
                        attempt: attempt,
                        owner: owner,
                        failures: failures,
                        resting: resting,
                        prompt: prompt
                    ),
                    waiters: server.waiters
                )
                return GUIStateTransition(state: put(state, updated))

            default:
                return GUIStateTransition(state: state)
            }

        case .promptCleared(let id, let targetAttempt, let promptID):
            guard let server = state.servers.first(where: { $0.config.id == id }),
                  case .authenticating(let attempt, let owner, let failures, let resting, let prompt) = server.phase,
                  attempt == targetAttempt,
                  prompt.id == promptID
            else {
                return GUIStateTransition(state: state)
            }
            let updated = ServerRecord(
                config: server.config,
                savedConfig: server.savedConfig,
                destination: server.destination,
                phase: .connecting(attempt: attempt, owner: owner, failures: failures, resting: resting),
                waiters: server.waiters
            )
            return GUIStateTransition(state: put(state, updated))

        case .attemptReady(let id, let targetAttempt, let http):
            guard let server = state.servers.first(where: { $0.config.id == id }),
                  activeAttempt(of: server.phase) == targetAttempt
            else {
                return GUIStateTransition(state: state)
            }
            let updated = ServerRecord(
                config: server.config,
                savedConfig: server.config,
                destination: server.destination,
                phase: .ready(attempt: targetAttempt, http: http),
                waiters: []
            )
            let nextState = put(state, updated)
            var effects: [Effect] = [saveEffect(servers: nextState.servers)]
            if !server.waiters.isEmpty {
                effects.append(.waitersResolve(waiters: server.waiters, http: http))
            }
            return GUIStateTransition(state: nextState, effects: effects)
        }
    }

    /// Computes a window's view of all SSH servers; prompts are visible only to the owning window.
    public static func selectServers(state: State, viewer: Int? = nil) -> [SSHItem] {
        state.servers.map { server in
            let stage: SSHStage
            var http: SSHHttp?
            var prompt: SSHPrompt?
            var authenticatingElsewhere = false
            var retrying: Bool?
            var detail = ""
            var error: SSHError?

            switch server.phase {
            case .disconnected:
                stage = .disconnected
            case .authentication:
                stage = .authentication
            case .incompatible(let d):
                stage = .incompatible
                detail = d
                error = .version
            case .connecting:
                stage = .connecting
            case .authenticating(_, let owner, _, _, let p):
                stage = .authentication
                if owner == viewer {
                    prompt = p
                } else {
                    authenticatingElsewhere = true
                }
            case .ready(_, let endpoint):
                stage = .ready
                http = endpoint
            case .failed(let code, let d, _, let retryAttempt):
                stage = .failed
                detail = d
                error = code
                if retryAttempt != nil {
                    retrying = true
                }
            }

            return SSHItem(
                config: server.config,
                saved: server.savedConfig != nil,
                destination: server.destination,
                stage: stage,
                http: http,
                prompt: prompt,
                authenticatingElsewhere: authenticatingElsewhere,
                retrying: retrying,
                detail: detail,
                error: error
            )
        }
    }

    public static func selectAuthenticating(state: State, id: String, attempt: Int) -> Bool {
        guard let phase = state.servers.first(where: { $0.config.id == id })?.phase,
              case .authenticating(let currentAttempt, _, _, _, _) = phase
        else {
            return false
        }
        return currentAttempt == attempt
    }

    private static func handleStart(state: State, request: SSHStart, owner: Int?) -> GUIStateTransition<State, Effect> {
        let id = request.id
        guard isValidServerID(id) else {
            return GUIStateTransition(state: state)
        }
        let server = state.servers.first(where: { $0.config.id == id })
        let phase = server?.phase ?? .disconnected

        if let activeOwner = ownerOf(phase), activeOwner != owner {
            return GUIStateTransition(state: state)
        }

        if request.background == true {
            if phase.isActive { return GUIStateTransition(state: state) }
            if case .ready = phase { return GUIStateTransition(state: state) }
        }

        let nextAttempt = state.issued + 1
        let config = SSHConfig(
            id: id,
            target: request.target.trimmingCharacters(in: .whitespacesAndNewlines),
            name: request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let failures: Int
        if request.background == true, case .failed(_, _, let priorFailures, _) = phase {
            failures = priorFailures
        } else {
            failures = 0
        }
        let record = ServerRecord(
            config: config,
            savedConfig: server?.savedConfig,
            destination: server?.destination,
            phase: .connecting(
                attempt: nextAttempt,
                owner: request.background == true ? nil : owner,
                failures: failures,
                resting: restingPhase(of: phase)
            ),
            waiters: server?.waiters ?? []
        )
        let nextState = put(State(status: state.status, issued: nextAttempt, servers: state.servers), record)
        let effects = haltEffects(for: phase) + [
            .attemptStart(id: id, attempt: nextAttempt, config: config, replace: request.replace == true),
        ]
        return GUIStateTransition(state: nextState, effects: effects)
    }

    private static func handleFailed(
        state: State,
        server: ServerRecord,
        reported: SSHError,
        detail: String,
        failures: Int
    ) -> GUIStateTransition<State, Effect> {
        let code: SSHError
        if detail.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") || detail.contains("Host key verification failed") {
            code = .hostKey
        } else if detail.contains("spawn ") && detail.contains("ENOENT") {
            code = .sshMissing
        } else {
            code = reported
        }

        let config = server.savedConfig ?? server.config

        if code == .version {
            let updated = ServerRecord(
                config: config,
                savedConfig: server.savedConfig,
                destination: server.destination,
                phase: .incompatible(detail: detail),
                waiters: []
            )
            return GUIStateTransition(state: put(state, updated), effects: releaseEffects(waiters: server.waiters))
        }

        let nonRetryable: Set<SSHError> = [.input, .platform, .unpublished, .hostKey, .sshMissing]
        let canRetry = server.savedConfig != nil
            && failures < retryLimit
            && !nonRetryable.contains(code)
            && !detail.contains("Permission denied")

        if !canRetry {
            let updated = ServerRecord(
                config: config,
                savedConfig: server.savedConfig,
                destination: server.destination,
                phase: .failed(code: code, detail: detail, failures: failures, retryAttempt: nil),
                waiters: []
            )
            return GUIStateTransition(state: put(state, updated), effects: releaseEffects(waiters: server.waiters))
        }

        let retryAttempt = state.issued + 1
        let updated = ServerRecord(
            config: config,
            savedConfig: server.savedConfig,
            destination: server.destination,
            phase: .failed(code: code, detail: detail, failures: failures, retryAttempt: retryAttempt),
            waiters: server.waiters
        )
        return GUIStateTransition(
            state: put(State(status: state.status, issued: retryAttempt, servers: state.servers), updated),
            effects: [.retrySchedule(id: server.config.id, attempt: retryAttempt, delayMs: retryDelayMs)]
        )
    }

    private static func handleCancel(state: State, id: String, owner: Int) -> GUIStateTransition<State, Effect> {
        guard let server = state.servers.first(where: { $0.config.id == id }) else {
            return GUIStateTransition(state: state)
        }
        let attempt: Int
        let resting: Resting
        switch server.phase {
        case .connecting(let a, let phaseOwner, _, let r) where phaseOwner == owner:
            attempt = a
            resting = r
        case .authenticating(let a, let phaseOwner, _, let r, _) where phaseOwner == owner:
            attempt = a
            resting = r
        default:
            return GUIStateTransition(state: state)
        }

        let effects: [Effect] = [.attemptStop(attempt: attempt)] + releaseEffects(waiters: server.waiters)

        guard let savedConfig = server.savedConfig else {
            return GUIStateTransition(
                state: State(status: state.status, issued: state.issued, servers: state.servers.filter { $0.config.id != id }),
                effects: effects
            )
        }

        let restoredPhase: ServerPhase
        switch resting {
        case .disconnected: restoredPhase = .disconnected
        case .authentication: restoredPhase = .authentication
        case .incompatible(let detail): restoredPhase = .incompatible(detail: detail)
        case .failed(let code, let detail, let failures):
            restoredPhase = .failed(code: code, detail: detail, failures: failures, retryAttempt: nil)
        }

        let updated = ServerRecord(
            config: savedConfig,
            savedConfig: savedConfig,
            destination: server.destination,
            phase: restoredPhase,
            waiters: []
        )
        return GUIStateTransition(state: put(state, updated), effects: effects)
    }

    private static func handleClose(state: State) -> GUIStateTransition<State, Effect> {
        let nextServers = state.servers.map {
            ServerRecord(
                config: $0.config,
                savedConfig: $0.savedConfig,
                destination: $0.destination,
                phase: .disconnected,
                waiters: []
            )
        }
        var effects = state.servers.flatMap { haltEffects(for: $0.phase) }
        let allWaiters = state.servers.flatMap(\.waiters)
        effects.append(contentsOf: releaseEffects(waiters: allWaiters))
        return GUIStateTransition(
            state: State(status: .closed, issued: state.issued, servers: nextServers),
            effects: effects
        )
    }

    private static func activeAttempt(of phase: ServerPhase) -> Int? {
        switch phase {
        case .connecting(let attempt, _, _, _), .authenticating(let attempt, _, _, _, _):
            return attempt
        default:
            return nil
        }
    }

    private static func ownerOf(_ phase: ServerPhase) -> Int? {
        switch phase {
        case .connecting(_, let owner, _, _): return owner
        case .authenticating(_, let owner, _, _, _): return owner
        default: return nil
        }
    }

    private static func restingPhase(of phase: ServerPhase) -> Resting {
        switch phase {
        case .connecting(_, _, _, let resting), .authenticating(_, _, _, let resting, _):
            return resting
        case .authentication:
            return .authentication
        case .incompatible(let detail):
            return .incompatible(detail: detail)
        case .failed(let code, let detail, let failures, _):
            return .failed(code: code, detail: detail, failures: failures)
        case .disconnected, .ready:
            return .disconnected
        }
    }

    private static func haltEffects(for phase: ServerPhase) -> [Effect] {
        switch phase {
        case .connecting(let attempt, _, _, _),
             .authenticating(let attempt, _, _, _, _),
             .ready(let attempt, _):
            return [.attemptStop(attempt: attempt)]
        case .failed(_, _, _, let retryAttempt?):
            return [.retryCancel(attempt: retryAttempt)]
        default:
            return []
        }
    }

    private static func releaseEffects(waiters: [Int]) -> [Effect] {
        waiters.isEmpty ? [] : [.waitersResolve(waiters: waiters, http: nil)]
    }

    private static func saveEffect(servers: [ServerRecord]) -> Effect {
        .configsSave(configs: servers.compactMap(\.savedConfig))
    }

    private static func put(_ state: State, _ record: ServerRecord) -> State {
        if let index = state.servers.firstIndex(where: { $0.config.id == record.config.id }) {
            var next = state.servers
            next[index] = record
            return State(status: state.status, issued: state.issued, servers: next)
        }
        return State(status: state.status, issued: state.issued, servers: state.servers + [record])
    }

    private static func isValidServerID(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard !bytes.isEmpty && bytes.count <= 80 else { return false }
        for byte in bytes {
            let ok = (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2D
            if !ok { return false }
        }
        return true
    }
}

// MARK: - SSH Window Machine (`ssh/window-machine.ts`)

public enum SSHWindowMachine: GUIStateMachine {
    public enum DialogSlot: String, Equatable, Hashable, Sendable {
        case none
        case loading
        case owned
    }

    public enum AttemptState: Equatable, Sendable {
        case starting(attempt: Int, dialog: DialogSlot, waiters: [Int])
        case waiting(attempt: Int, dialog: DialogSlot, answered: String?, error: Bool, waiters: [Int])
        case answering(attempt: Int, dialog: DialogSlot, prompt: String, waiters: [Int])
        case failed

        public var isActive: Bool {
            if case .failed = self { return false }
            return true
        }

        public var isCalling: Bool {
            switch self {
            case .starting, .answering: return true
            case .waiting, .failed: return false
            }
        }

        public var waiters: [Int] {
            switch self {
            case .starting(_, _, let w), .waiting(_, _, _, _, let w), .answering(_, _, _, let w):
                return w
            case .failed:
                return []
            }
        }

        public var attemptID: Int? {
            switch self {
            case .starting(let a, _, _), .waiting(let a, _, _, _, _), .answering(let a, _, _, _):
                return a
            case .failed:
                return nil
            }
        }
    }

    public enum LifecycleStatus: String, Equatable, Sendable {
        case open
        case disposed
    }

    public struct State: Equatable, Sendable {
        public let status: LifecycleStatus
        public let issued: Int
        public let attempts: [String: AttemptState]
        public let restored: Set<String>
        public let visit: String?
        public let offered: Set<String>

        public init(
            status: LifecycleStatus = .open,
            issued: Int = 0,
            attempts: [String: AttemptState] = [:],
            restored: Set<String> = [],
            visit: String? = nil,
            offered: Set<String> = []
        ) {
            self.status = status
            self.issued = issued
            self.attempts = attempts
            self.restored = restored
            self.visit = visit
            self.offered = offered
        }
    }

    public enum Event: Equatable, Sendable {
        case connectRequested(
            config: SSHConfig,
            ipcActive: Bool,
            item: SSHItem? = nil,
            dialog: Bool = false,
            replace: Bool = false,
            waiterID: Int? = nil
        )
        case startConfirmed(id: String, attempt: Int, item: SSHItem?)
        case startFailed(id: String, attempt: Int)
        case respondRequested(id: String, prompt: String, value: String, ipcActive: Bool, item: SSHItem?)
        case respondSucceeded(id: String, attempt: Int, item: SSHItem?)
        case respondFailed(id: String, attempt: Int)
        case dialogLoading(id: String, attempt: Int)
        case dialogOpened(id: String, attempt: Int)
        case dialogFailed(id: String, attempt: Int, saved: Bool)
        case cancelRequested(id: String, saved: Bool)
        case itemsSynced(ipcActive: Bool, items: [SSHItem])
        case visitChanged(path: String)
        case coverOffered(id: String, path: String, dialogActive: Bool, ipcActive: Bool, item: SSHItem?)
        case disposed
    }

    public enum Effect: Equatable, Sendable {
        case rpcStart(id: String, attempt: Int, config: SSHConfig, replace: Bool)
        case rpcRespond(id: String, attempt: Int, prompt: String, value: String)
        case rpcCancel(id: String, forget: Bool)
        case rpcRestore(config: SSHConfig)
        case taskAbort(id: String)
        case toastError
        case waitersNotify(waiters: [Int], ready: Bool)
    }

    public struct PromptTarget: Equatable, Sendable {
        public let item: SSHItem
        public let attempt: Int

        public init(item: SSHItem, attempt: Int) {
            self.item = item
            self.attempt = attempt
        }
    }

    public static func createState() -> State {
        State()
    }

    public static func reduce(state: State, event: Event) -> GUIStateTransition<State, Effect> {
        if state.status == .disposed {
            if case .connectRequested(_, _, _, _, _, let waiter?) = event {
                return GUIStateTransition(state: state, effects: [.waitersNotify(waiters: [waiter], ready: false)])
            }
            return GUIStateTransition(state: state)
        }

        switch event {
        case .disposed:
            var effects: [Effect] = []
            var allWaiters: [Int] = []
            for key in state.attempts.keys.sorted() {
                if let attempt = state.attempts[key] {
                    if attempt.isCalling {
                        effects.append(.taskAbort(id: key))
                    }
                    if attempt.isActive {
                        allWaiters.append(contentsOf: attempt.waiters)
                    }
                }
            }
            if !allWaiters.isEmpty {
                effects.append(.waitersNotify(waiters: allWaiters, ready: false))
            }
            return GUIStateTransition(
                state: State(
                    status: .disposed,
                    issued: state.issued,
                    attempts: [:],
                    restored: state.restored,
                    visit: state.visit,
                    offered: state.offered
                ),
                effects: effects
            )

        case .itemsSynced(let ipcActive, let items):
            return handleItemsSynced(state: state, ipcActive: ipcActive, items: items)

        case .connectRequested(let config, let ipcActive, let item, let dialog, let replace, let waiterID):
            return handleConnect(
                state: state,
                config: config,
                ipcActive: ipcActive,
                item: item,
                dialog: dialog,
                replace: replace,
                waiterID: waiterID
            )

        case .visitChanged(let path):
            if state.visit == path { return GUIStateTransition(state: state) }
            return GUIStateTransition(
                state: State(
                    status: state.status,
                    issued: state.issued,
                    attempts: state.attempts,
                    restored: state.restored,
                    visit: path,
                    offered: []
                )
            )

        case .coverOffered(let id, let path, let dialogActive, let ipcActive, let item):
            guard let item,
                  canOffer(state: state, id: id, path: path, dialogActive: dialogActive, ipcActive: ipcActive, item: item)
            else {
                return GUIStateTransition(state: state)
            }
            let next = handleConnect(
                state: state,
                config: item.config,
                ipcActive: true,
                item: item,
                dialog: false,
                replace: false,
                waiterID: nil
            )
            var nextOffered = state.visit == path ? state.offered : Set<String>()
            nextOffered.insert(id)
            return GUIStateTransition(
                state: State(
                    status: next.state.status,
                    issued: next.state.issued,
                    attempts: next.state.attempts,
                    restored: next.state.restored,
                    visit: path,
                    offered: nextOffered
                ),
                effects: next.effects
            )

        case .cancelRequested(let id, let saved):
            let cancelEffect: Effect = .rpcCancel(id: id, forget: !saved)
            guard let current = state.attempts[id] else {
                return GUIStateTransition(state: state, effects: [cancelEffect])
            }
            var effects: [Effect] = []
            if current.isCalling {
                effects.append(.taskAbort(id: id))
            }
            if current.isActive && !current.waiters.isEmpty {
                effects.append(.waitersNotify(waiters: current.waiters, ready: false))
            }
            effects.append(cancelEffect)
            return GUIStateTransition(state: removing(state, id: id), effects: effects)

        case .respondRequested(let id, let prompt, let value, let ipcActive, let item):
            guard case .waiting(_, let dialog, let answered, let hasError, let waiters) = state.attempts[id] else {
                return GUIStateTransition(state: state)
            }
            if !ipcActive {
                var effects: [Effect] = [.toastError]
                if !waiters.isEmpty {
                    effects.append(.waitersNotify(waiters: waiters, ready: false))
                }
                return GUIStateTransition(state: setting(state, id: id, attempt: .failed), effects: effects)
            }
            if item?.prompt?.id != prompt || (answered == prompt && !hasError) {
                return GUIStateTransition(state: state)
            }
            let nextAttempt = state.issued + 1
            let nextState = setting(
                State(
                    status: state.status,
                    issued: nextAttempt,
                    attempts: state.attempts,
                    restored: state.restored,
                    visit: state.visit,
                    offered: state.offered
                ),
                id: id,
                attempt: .answering(attempt: nextAttempt, dialog: dialog, prompt: prompt, waiters: waiters)
            )
            return GUIStateTransition(
                state: nextState,
                effects: [.rpcRespond(id: id, attempt: nextAttempt, prompt: prompt, value: value)]
            )

        case .startConfirmed(let id, let attempt, let item):
            guard case .starting(let currentAttempt, let dialog, let waiters) = state.attempts[id],
                  currentAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            return wait(
                state: state,
                id: id,
                attempt: currentAttempt,
                dialog: dialog,
                answered: nil,
                error: false,
                waiters: waiters,
                item: item
            )

        case .startFailed(let id, let attempt):
            guard case .starting(let currentAttempt, let dialog, let waiters) = state.attempts[id],
                  currentAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            var effects: [Effect] = []
            if !waiters.isEmpty {
                effects.append(.waitersNotify(waiters: waiters, ready: false))
            }
            if dialog == .none {
                effects.append(.toastError)
            }
            return GUIStateTransition(state: setting(state, id: id, attempt: .failed), effects: effects)

        case .respondSucceeded(let id, let attempt, let item):
            guard case .answering(let currentAttempt, let dialog, let prompt, let waiters) = state.attempts[id],
                  currentAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            return wait(
                state: state,
                id: id,
                attempt: currentAttempt,
                dialog: dialog,
                answered: prompt,
                error: false,
                waiters: waiters,
                item: item
            )

        case .respondFailed(let id, let attempt):
            guard case .answering(let currentAttempt, let dialog, _, let waiters) = state.attempts[id],
                  currentAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: setting(
                    state,
                    id: id,
                    attempt: .waiting(attempt: currentAttempt, dialog: dialog, answered: nil, error: true, waiters: waiters)
                ),
                effects: dialog == .none ? [.toastError] : []
            )

        case .dialogLoading(let id, let attempt):
            guard case .waiting(let currentAttempt, .none, let answered, let error, let waiters) = state.attempts[id],
                  currentAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: setting(
                    state,
                    id: id,
                    attempt: .waiting(attempt: currentAttempt, dialog: .loading, answered: answered, error: error, waiters: waiters)
                )
            )

        case .dialogOpened(let id, let attempt):
            guard case .waiting(let currentAttempt, .loading, let answered, let error, let waiters) = state.attempts[id],
                  currentAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            return GUIStateTransition(
                state: setting(
                    state,
                    id: id,
                    attempt: .waiting(attempt: currentAttempt, dialog: .owned, answered: answered, error: error, waiters: waiters)
                )
            )

        case .dialogFailed(let id, let attempt, let saved):
            guard case .waiting(let currentAttempt, .loading, _, _, let waiters) = state.attempts[id],
                  currentAttempt == attempt
            else {
                return GUIStateTransition(state: state)
            }
            var effects: [Effect] = []
            if !waiters.isEmpty {
                effects.append(.waitersNotify(waiters: waiters, ready: false))
            }
            effects.append(.toastError)
            effects.append(.rpcCancel(id: id, forget: !saved))
            return GUIStateTransition(state: setting(state, id: id, attempt: .failed), effects: effects)
        }
    }

    // MARK: Selectors

    public static func submitting(state: State, id: String) -> Bool {
        state.attempts[id]?.isCalling ?? false
    }

    public static func error(state: State, id: String) -> Bool {
        switch state.attempts[id] {
        case .failed:
            return true
        case .waiting(_, _, _, let hasError, _):
            return hasError
        default:
            return false
        }
    }

    public static func answeredPrompt(state: State, id: String) -> String? {
        switch state.attempts[id] {
        case .answering(_, _, let prompt, _):
            return prompt
        case .waiting(_, _, let answered, let hasError, _) where !hasError:
            return answered
        default:
            return nil
        }
    }

    public static func activeAttempt(state: State, id: String) -> Bool {
        state.attempts[id]?.isActive ?? false
    }

    public static func canOffer(
        state: State,
        id: String,
        path: String,
        dialogActive: Bool,
        ipcActive: Bool,
        item: SSHItem?
    ) -> Bool {
        state.status == .open
            && ipcActive
            && !dialogActive
            && item?.stage == .authentication
            && item?.authenticatingElsewhere != true
            && !(state.visit == path && state.offered.contains(id))
    }

    public static func pending(state: State, id: String, item: SSHItem?) -> Bool {
        submitting(state: state, id: id)
            || item?.authenticatingElsewhere == true
            || item?.stage == .connecting
    }

    public static func promptTarget(state: State, items: [SSHItem]) -> PromptTarget? {
        for item in items {
            if case .waiting(let attempt, .none, _, let hasError, _) = state.attempts[item.config.id],
               !hasError,
               item.prompt != nil || item.stage == .incompatible
            {
                return PromptTarget(item: item, attempt: attempt)
            }
        }
        return nil
    }

    public static func canOpenDialog(state: State, id: String, attempt: Int) -> Bool {
        if case .waiting(let currentAttempt, .loading, _, _, _) = state.attempts[id] {
            return currentAttempt == attempt
        }
        return false
    }

    public static func resolvable(ipcActive: Bool, item: SSHItem?) -> Bool {
        guard ipcActive, let item else { return false }
        return item.stage == .ready
            || item.stage == .connecting
            || item.authenticatingElsewhere == true
            || (item.stage == .failed && item.retrying == true)
    }

    // MARK: Internal Helpers

    private static func handleConnect(
        state: State,
        config: SSHConfig,
        ipcActive: Bool,
        item: SSHItem?,
        dialog: Bool,
        replace: Bool,
        waiterID: Int?
    ) -> GUIStateTransition<State, Effect> {
        let id = config.id
        let current = state.attempts[id]
        var waiters: [Int] = []
        if let current, current.isActive {
            waiters.append(contentsOf: current.waiters)
        }
        if let waiterID {
            waiters.append(waiterID)
        }

        if !ipcActive {
            var effects: [Effect] = []
            if current?.isCalling == true {
                effects.append(.taskAbort(id: id))
            }
            effects.append(.toastError)
            if !waiters.isEmpty {
                effects.append(.waitersNotify(waiters: waiters, ready: false))
            }
            return GUIStateTransition(state: setting(state, id: id, attempt: .failed), effects: effects)
        }

        if item?.authenticatingElsewhere == true {
            let effects: [Effect] = waiterID.map { [.waitersNotify(waiters: [$0], ready: false)] } ?? []
            return GUIStateTransition(state: state, effects: effects)
        }

        if let current, current.isActive, !replace {
            let isErroredWaiting: Bool
            if case .waiting(_, _, _, true, _) = current { isErroredWaiting = true } else { isErroredWaiting = false }
            if !isErroredWaiting {
                let updated: AttemptState
                switch current {
                case .starting(let a, let d, _):
                    updated = .starting(attempt: a, dialog: (dialog && d == .none) ? .owned : d, waiters: waiters)
                case .waiting(let a, let d, let ans, let err, _):
                    updated = .waiting(
                        attempt: a,
                        dialog: (dialog && d == .none) ? .owned : d,
                        answered: ans,
                        error: err,
                        waiters: waiters
                    )
                case .answering(let a, let d, let p, _):
                    updated = .answering(
                        attempt: a,
                        dialog: (dialog && d == .none) ? .owned : d,
                        prompt: p,
                        waiters: waiters
                    )
                case .failed:
                    updated = .failed
                }
                return GUIStateTransition(state: setting(state, id: id, attempt: updated))
            }
        }

        let nextAttempt = state.issued + 1
        let priorDialog: DialogSlot
        if dialog {
            priorDialog = .owned
        } else {
            switch current {
            case .starting(_, let d, _), .waiting(_, let d, _, _, _), .answering(_, let d, _, _):
                priorDialog = d
            default:
                priorDialog = .none
            }
        }
        var effects: [Effect] = []
        if current?.isCalling == true {
            effects.append(.taskAbort(id: id))
        }
        effects.append(.rpcStart(id: id, attempt: nextAttempt, config: config, replace: replace))

        let nextState = setting(
            State(
                status: state.status,
                issued: nextAttempt,
                attempts: state.attempts,
                restored: state.restored,
                visit: state.visit,
                offered: state.offered
            ),
            id: id,
            attempt: .starting(attempt: nextAttempt, dialog: priorDialog, waiters: waiters)
        )
        return GUIStateTransition(state: nextState, effects: effects)
    }

    private static func handleItemsSynced(
        state: State,
        ipcActive: Bool,
        items: [SSHItem]
    ) -> GUIStateTransition<State, Effect> {
        let unseen = items.filter { $0.saved && !state.restored.contains($0.config.id) }
        var settled: [(id: String, waiters: [Int], ready: Bool)] = []
        for id in state.attempts.keys.sorted() {
            guard case .waiting(_, let dialog, _, _, let waiters) = state.attempts[id] else { continue }
            if let outcome = settleOutcome(dialog: dialog, item: items.first(where: { $0.config.id == id })) {
                settled.append((id: id, waiters: waiters, ready: outcome))
            }
        }
        if unseen.isEmpty && settled.isEmpty {
            return GUIStateTransition(state: state)
        }
        var nextAttempts = state.attempts
        for item in settled {
            nextAttempts.removeValue(forKey: item.id)
        }
        var nextRestored = state.restored
        for item in unseen {
            nextRestored.insert(item.config.id)
        }
        var effects: [Effect] = []
        if ipcActive {
            for item in unseen where item.stage == .disconnected {
                effects.append(.rpcRestore(config: item.config))
            }
        }
        for item in settled where !item.waiters.isEmpty {
            effects.append(.waitersNotify(waiters: item.waiters, ready: item.ready))
        }
        return GUIStateTransition(
            state: State(
                status: state.status,
                issued: state.issued,
                attempts: nextAttempts,
                restored: nextRestored,
                visit: state.visit,
                offered: state.offered
            ),
            effects: effects
        )
    }

    private static func wait(
        state: State,
        id: String,
        attempt: Int,
        dialog: DialogSlot,
        answered: String?,
        error: Bool,
        waiters: [Int],
        item: SSHItem?
    ) -> GUIStateTransition<State, Effect> {
        if let outcome = settleOutcome(dialog: dialog, item: item) {
            let effects: [Effect] = waiters.isEmpty ? [] : [.waitersNotify(waiters: waiters, ready: outcome)]
            return GUIStateTransition(state: removing(state, id: id), effects: effects)
        }
        return GUIStateTransition(
            state: setting(
                state,
                id: id,
                attempt: .waiting(attempt: attempt, dialog: dialog, answered: answered, error: error, waiters: waiters)
            )
        )
    }

    private static func settleOutcome(dialog: DialogSlot, item: SSHItem?) -> Bool? {
        guard let item else { return false }
        if item.stage == .ready { return true }
        if item.stage == .failed || item.stage == .disconnected || item.authenticatingElsewhere == true {
            return false
        }
        if dialog != .none && item.stage == .authentication && item.prompt == nil {
            return false
        }
        return nil
    }

    private static func setting(_ state: State, id: String, attempt: AttemptState) -> State {
        var next = state.attempts
        next[id] = attempt
        return State(
            status: state.status,
            issued: state.issued,
            attempts: next,
            restored: state.restored,
            visit: state.visit,
            offered: state.offered
        )
    }

    private static func removing(_ state: State, id: String) -> State {
        var next = state.attempts
        next.removeValue(forKey: id)
        return State(
            status: state.status,
            issued: state.issued,
            attempts: next,
            restored: state.restored,
            visit: state.visit,
            offered: state.offered
        )
    }
}

// MARK: - Injectable SSH Controller (`ssh/controller.ts`)

/// Injectable backend driver executing `SSHMainMachine` side effects.
public protocol SSHBackendDriver: Sendable {
    func startAttempt(id: String, attempt: Int, config: SSHConfig, replace: Bool) async
    func stopAttempt(attempt: Int) async
    func respondAttempt(attempt: Int, promptID: String, value: String) async
    func scheduleRetry(id: String, attempt: Int, delayMs: Int) async
    func cancelRetry(attempt: Int) async
    func probeHealth(http: SSHHttp) async -> Bool
    func saveConfigs(_ configs: [SSHConfig]) async
}

/// Actor owning the main-process SSH state machine, revision counter, and resolve waiters.
public actor SSHController {
    private var machineState: SSHMainMachine.State
    private var revision = 0
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<SSHHttp?, Never>] = [:]
    private let driver: any SSHBackendDriver

    public init(configs: [SSHConfig] = [], driver: any SSHBackendDriver) {
        self.machineState = SSHMainMachine.createState(configs: configs)
        self.driver = driver
    }

    public func state(viewer: Int? = nil) -> SSHState {
        SSHState(servers: SSHMainMachine.selectServers(state: machineState, viewer: viewer), revision: revision)
    }

    public func isAuthenticating(id: String, attempt: Int) -> Bool {
        SSHMainMachine.selectAuthenticating(state: machineState, id: id, attempt: attempt)
    }

    @discardableResult
    public func start(_ request: SSHStart, owner: Int? = nil) async -> Int {
        await dispatch(.start(request: request, owner: owner))
        return revision
    }

    public func respond(id: String, promptID: String, value: String, owner: Int) async {
        await dispatch(.respond(id: id, promptID: promptID, value: value, owner: owner))
    }

    public func cancel(id: String, owner: Int) async {
        await dispatch(.cancel(id: id, owner: owner))
    }

    public func forget(id: String) async {
        await dispatch(.forget(id: id))
    }

    public func detach(owner: Int) async {
        await dispatch(.windowDetached(owner: owner))
    }

    public func close() async {
        await dispatch(.close)
    }

    public func report(_ event: SSHMainMachine.Event) async {
        await dispatch(event)
    }

    /// Waits until the server is ready (with healthy endpoint) or stops reconnecting (`nil`).
    public func resolve(id: String) async -> SSHHttp? {
        nextWaiterID += 1
        let waiterID = nextWaiterID
        return await withCheckedContinuation { continuation in
            waiters[waiterID] = continuation
            Task {
                await self.dispatch(.resolveRequested(id: id, waiter: waiterID))
            }
        }
    }

    private func dispatch(_ event: SSHMainMachine.Event) async {
        let previous = machineState
        let transition = SSHMainMachine.reduce(state: previous, event: event)
        machineState = transition.state
        if transition.state != previous {
            revision += 1
        }
        for effect in transition.effects {
            await perform(effect)
        }
    }

    private func perform(_ effect: SSHMainMachine.Effect) async {
        switch effect {
        case .attemptStart(let id, let attempt, let config, let replace):
            await driver.startAttempt(id: id, attempt: attempt, config: config, replace: replace)
        case .attemptStop(let attempt):
            await driver.stopAttempt(attempt: attempt)
        case .attemptRespond(let attempt, let promptID, let value):
            await driver.respondAttempt(attempt: attempt, promptID: promptID, value: value)
        case .retrySchedule(let id, let attempt, let delayMs):
            await driver.scheduleRetry(id: id, attempt: attempt, delayMs: delayMs)
        case .retryCancel(let attempt):
            await driver.cancelRetry(attempt: attempt)
        case .healthProbe(let id, let attempt, let http, let waiter):
            let healthy = await driver.probeHealth(http: http)
            await dispatch(.healthProbed(id: id, attempt: attempt, waiter: waiter, healthy: healthy))
        case .waitersResolve(let waiterIDs, let http):
            for id in waiterIDs {
                if let continuation = waiters.removeValue(forKey: id) {
                    continuation.resume(returning: http)
                }
            }
        case .configsSave(let configs):
            await driver.saveConfigs(configs)
        }
    }
}

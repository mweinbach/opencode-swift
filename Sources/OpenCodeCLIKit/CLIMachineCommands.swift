#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeClient
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Remote machine CLI commands & formatting helpers (`packages/cli/src/commands/handlers/machine/*`).
public enum CLIMachine {
    /// Resolves a client for managing remote machines, rejecting `--standalone` and disabled background service.
    // parity: cli/src/commands/handlers/machine/common.ts#ensureMachineClient [status=implemented hash=aaa1c636c9c0]
    public static func ensureMachineClient(
        context: CLIContext = CLIContext.current
    ) async throws -> OpenCodeClient {
        if context.globalFlags.standalone {
            throw CLIError("--standalone starts a server for this command only; a machine needs one that keeps running.")
        }
        let serverFlag = context.globalFlags.server
        let config = try await CLIServices.ServiceConfig.read(context: context)
        if serverFlag == nil && config.disabled == true {
            throw CLIError("Managing machines requires the background service; run `opencode service unset disabled` first.")
        }
        let server = try await CLIServices.ServerConnection.resolve(
            CLIServices.ServerConnection.Args(
                server: serverFlag,
                standalone: nil
            ),
            context: context
        )
        return context.makeClient(endpoint: server.endpoint)
    }

    /// Converts HTTP(S) server URLs into deduplicated WebSocket machine-link reach addresses, ordering non-loopback
    /// addresses first and loopback addresses last.
    // parity: cli/src/commands/handlers/machine/common.ts#machineReach [status=implemented hash=3f3528045b57]
    public static func machineReach(_ urls: [String]) -> [OpenCodeProtocol.MachineReach] {
        struct Entry {
            let href: String
            let loopback: Bool
        }
        let parsed: [Entry] = urls.compactMap { raw in
            guard var comps = URLComponents(string: raw),
                  let scheme = comps.scheme?.lowercased(),
                  let host = CLIServiceURLs.whatwgHostname(from: comps)
            else {
                return nil
            }
            comps.scheme = (scheme == "https") ? "wss" : "ws"
            comps.path = OpenCodeProtocol.MACHINE_LINK_PATH
            comps.query = nil
            comps.fragment = nil
            guard let href = comps.url?.absoluteString else { return nil }
            return Entry(href: href, loopback: CLIServiceURLs.isLoopback(host))
        }
        let ordered = parsed.filter { !$0.loopback } + parsed.filter { $0.loopback }
        var seen: Set<String> = []
        var result: [OpenCodeProtocol.MachineReach] = []
        for entry in ordered {
            if seen.insert(entry.href).inserted {
                result.append(OpenCodeProtocol.MachineReach(url: entry.href))
            }
        }
        return result
    }

    public struct FormatAddInput: Equatable, Sendable {
        public let name: String
        public let join: String
        public let expires: Int64
        public let reach: [OpenCodeProtocol.MachineInvite.ReachEntry]
        public let tty: Bool
        public let now: Int64?
        public let eol: String

        public init(
            name: String,
            join: String,
            expires: Int64,
            reach: [OpenCodeProtocol.MachineInvite.ReachEntry],
            tty: Bool,
            now: Int64? = nil,
            eol: String = CLIContext.current.io.eol
        ) {
            self.name = name
            self.join = join
            self.expires = expires
            self.reach = reach
            self.tty = tty
            self.now = now
            self.eol = eol
        }
    }

    /// Formats `opencode machine add` output: raw join string when stdout is non-TTY, or human-readable invite details on a TTY.
    // parity: cli/src/commands/handlers/machine/common.ts#formatMachineAdd [status=implemented hash=11d214cadc46]
    public static func formatMachineAdd(_ input: FormatAddInput) -> String {
        if !input.tty {
            return input.join + input.eol
        }
        let addresses: [String] = input.reach.isEmpty
            ? ["  (none)"]
            : input.reach.map { entry in
                switch entry {
                case .iroh: return "  iroh"
                case .url(let url): return "  \(url)"
                }
            }
        let hasIroh = input.reach.contains { entry in
            if case .iroh = entry { return true }
            return false
        }
        let hasNonLoopbackURL = input.reach.contains { entry in
            guard case .url(let url) = entry,
                  let comps = URLComponents(string: url),
                  let host = CLIServiceURLs.whatwgHostname(from: comps)
            else {
                return false
            }
            return !CLIServiceURLs.isLoopback(host)
        }
        let access: String
        if hasIroh {
            access = "Works from any network."
        } else if hasNonLoopbackURL {
            access = "Works from computers that can reach one of these addresses."
        } else {
            access = "Only works on this computer. Pass --url with an address other computers can reach."
        }
        let nowMs = input.now ?? Flock.currentEpochMs()
        let lines: [String] = [
            "Machine: \(input.name)",
            formatExpiry(expires: input.expires, now: nowMs),
            "",
            input.join,
            "",
            access,
            "Addresses:",
        ] + addresses
        return lines.joined(separator: input.eol) + input.eol
    }

    /// Formats `opencode machine list` rows with aligned columns and optional platform / carrier details.
    // parity: cli/src/commands/handlers/machine/common.ts#formatMachineList [status=implemented hash=f6b73705065a]
    public static func formatMachineList(
        _ machines: [OpenCodeProtocol.MachineInfo],
        eol: String = CLIContext.current.io.eol
    ) -> String {
        if machines.isEmpty { return "No machines added." }
        let nameWidth = machines.map(\.id.count).max() ?? 0
        let pairedWidth = machines.map { ($0.paired ? "paired" : "waiting").count }.max() ?? 0
        let onlineWidth = machines.map { ($0.online ? "connected" : "offline").count }.max() ?? 0
        return machines.map { machine in
            let paired = padEnd(machine.paired ? "paired" : "waiting", to: pairedWidth)
            let online = machine.online ? "connected" : "offline"
            let platform: String?
            if let os = machine.os, !os.isEmpty, let arch = machine.arch, !arch.isEmpty {
                platform = "\(os)/\(arch)"
            } else {
                platform = machine.os ?? machine.arch
            }
            let connection = machine.online ? machine.connection : nil
            let carrier: String? = connection.map { conn in
                var parts: [String] = [conn.kind.rawValue]
                if let path = conn.path {
                    parts.append(path.rawValue)
                }
                if let rtt = conn.rtt {
                    parts.append("\(Int(rtt.rounded()))ms")
                }
                return parts.joined(separator: " ")
            }
            let detailParts = [platform, carrier].compactMap { $0 }
            let details = detailParts.joined(separator: "  ")
            if details.isEmpty {
                return "\(padEnd(machine.id, to: nameWidth))  \(paired)  \(online)"
            }
            return "\(padEnd(machine.id, to: nameWidth))  \(paired)  \(padEnd(online, to: onlineWidth))  \(details)"
        }.joined(separator: eol)
    }

    /// Formats protocol errors from `experimental.machine.*` into actionable CLI guidance.
    // parity: cli/src/commands/handlers/machine/common.ts#formatMachineError [status=implemented hash=c9c12c3eddf8]
    public static func formatMachineError(_ error: any Error, name: String? = nil) -> String {
        if isForbiddenError(error) {
            return "Machines are experimental and disabled on this server. Turn them on with OPENCODE_FLAGS=machines or experimental.machines: true in your config."
        }
        if isInvalidRequestError(error), invalidRequestKind(error) == "invalid_name" {
            let label = name.map(jsonQuote) ?? "That name"
            return "\(label) is not a valid machine name. Use lowercase letters, digits, and hyphens, starting with a letter, 2 to 63 characters, and not \"local\"."
        }
        if isMachineNotFoundError(error) {
            let target = name ?? machineNotFoundName(error) ?? ""
            return "No machine named \(jsonQuote(target))."
        }
        if isConflictError(error) {
            let target = name ?? conflictResource(error)
            let label = target.map { "Machine \(jsonQuote($0))" } ?? "This machine"
            return "\(label) is already paired. Pass --replace to issue a new join string; once the new computer joins, the computer currently paired stops being able to connect."
        }
        return CLIUtil.errorMessage(error)
    }

    /// Writes the formatted machine error to stderr and sets exit code 1.
    // parity: cli/src/commands/handlers/machine/common.ts#reportMachineError [status=implemented hash=2d33754c37a0]
    public static func reportMachineError(
        _ error: any Error,
        name: String? = nil,
        context: CLIContext = CLIContext.current
    ) {
        context.io.writeStderr(formatMachineError(error, name: name) + context.io.eol)
        context.exitCode.value = 1
    }

    /// `opencode machine add <name> [--url <url>] [--replace]` (`cli/src/commands/handlers/machine/add.ts#default`).
    // parity: cli/src/commands/handlers/machine/add.ts#default [status=implemented hash=5045c31b1f1f]
    public static func runAdd(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
        let name = input.arg("name") ?? ""
        do {
            let urlOverride = try input.string("url").map(CLIServiceURLs.parseServerURL)
            let replaceFlag = input.bool("replace")
            let client = try await ensureMachineClient(context: context)
            let urls = try await CLIServiceURLs.serverURLs(client: client, url: urlOverride)
            let reach = machineReach(urls)
            let invited = try await client.experimental.machine.add(
                ExperimentalMachineAddInput(
                    name: name,
                    reach: reach,
                    replace: replaceFlag ? true : nil
                )
            )
            let displayReach: [OpenCodeProtocol.MachineInvite.ReachEntry] =
                invited.reach.isEmpty && !reach.isEmpty
                    ? reach.map { .url($0.url) }
                    : invited.reach
            context.io.writeStdout(
                formatMachineAdd(
                    FormatAddInput(
                        name: invited.name,
                        join: invited.join,
                        expires: invited.expires,
                        reach: displayReach,
                        tty: context.io.isStdoutTTY(),
                        eol: context.io.eol
                    )
                )
            )
        } catch {
            reportMachineError(error, name: name, context: context)
        }
    }

    /// `opencode machine list` (`cli/src/commands/handlers/machine/list.ts#default`).
    // parity: cli/src/commands/handlers/machine/list.ts#default [status=implemented hash=517d3b9ac0cf]
    public static func runList(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
        _ = input
        do {
            let client = try await ensureMachineClient(context: context)
            let machines = try await client.experimental.machine.list()
            context.io.writeStdout(formatMachineList(machines, eol: context.io.eol) + context.io.eol)
        } catch {
            reportMachineError(error, context: context)
        }
    }

    /// `opencode machine remove <name>` (`cli/src/commands/handlers/machine/remove.ts#default`).
    // parity: cli/src/commands/handlers/machine/remove.ts#default [status=implemented hash=93daf19ee172]
    public static func runRemove(_ input: CLIFramework.Runtime.Input, context: CLIContext) async throws {
        let name = input.arg("name") ?? ""
        do {
            let client = try await ensureMachineClient(context: context)
            try await client.experimental.machine.remove(ExperimentalMachineRemoveInput(name: name))
            context.io.writeStdout("Removed machine \(name).\(context.io.eol)")
        } catch {
            reportMachineError(error, name: name, context: context)
        }
    }

    // MARK: - Helpers

    private static func padEnd(_ text: String, to width: Int) -> String {
        guard text.count < width else { return text }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func jsonQuote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func formatExpiry(expires: Int64, now: Int64) -> String {
        let remaining = max(Int64(0), expires - now)
        let minutes = Int((Double(remaining) / 60_000.0).rounded())
        let date = Date(timeIntervalSince1970: Double(expires) / 1000.0)
        let at = formatLocalHourMinute(date)
        if minutes == 0 {
            return "Expires in less than a minute (at \(at))."
        }
        return "Expires in \(minutes) \(minutes == 1 ? "minute" : "minutes") (at \(at))."
    }

    private static func formatLocalHourMinute(_ date: Date) -> String {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let h = comps.hour ?? 0
        let m = comps.minute ?? 0
        let hh = h < 10 ? "0\(h)" : "\(h)"
        let mm = m < 10 ? "0\(m)" : "\(m)"
        return "\(hh):\(mm)"
    }

    private static func invalidRequestKind(_ error: any Error) -> String? {
        if let e = error as? OpenCodeProtocol.InvalidRequestError { return e.kind }
        if let env = error as? ProtocolErrorEnvelope, case .invalidRequest(let e) = env { return e.kind }
        if let declared = error as? DeclaredAPIError,
           case .object(let fields) = declared.body,
           case .string(let kind)? = fields["kind"]
        {
            return kind
        }
        return nil
    }

    private static func machineNotFoundName(_ error: any Error) -> String? {
        if let e = error as? OpenCodeProtocol.MachineNotFoundError { return e.machine }
        if let env = error as? ProtocolErrorEnvelope, case .machineNotFound(let e) = env { return e.machine }
        if let declared = error as? DeclaredAPIError,
           case .object(let fields) = declared.body,
           case .string(let machine)? = fields["machine"]
        {
            return machine
        }
        return nil
    }

    private static func conflictResource(_ error: any Error) -> String? {
        if let e = error as? OpenCodeProtocol.ConflictError { return e.resource }
        if let env = error as? ProtocolErrorEnvelope, case .conflict(let e) = env { return e.resource }
        if let declared = error as? DeclaredAPIError,
           case .object(let fields) = declared.body,
           case .string(let resource)? = fields["resource"]
        {
            return resource
        }
        return nil
    }
}

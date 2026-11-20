import OpenCodePlatform
import OpenCodeUtil

/// Port of `core/src/machine/instructions.ts`: tells the model which machines a tool path can name.
public enum MachineInstructions {
    public typealias Instructions = CoreInstruction.Instructions

    static func render(_ names: [String]) -> String {
        [
            "Other machines are available: \(names.joined(separator: ", ")).",
            "Name one in a path, as in \(names.first ?? ""):/work/file, for the read, write, edit and patch tools, and as the shell tool's workdir to run a command there. A machine path is absolute or starts with ~/ for that machine's home. grep and glob cannot search another machine; run a search command there with the shell tool instead. A machine may be offline; the tool says so when it is.",
        ].joined(separator: "\n")
    }

    static let update: @Sendable ([String], [String]) -> String = Instructions.listUpdate(
        key: { $0 },
        changed: { _, _ in false },
        entries: { names in [names.joined(separator: ", ")] },
        render: { render($0) },
        text: Instructions.ListUpdateText(
            replaced: "The available machines have changed. This list supersedes the previous available machines list.",
            added: "New machines are available in addition to those previously listed:",
            changed: "The following machines have changed. Each entry replaces the previously listed machine with the same name:",
            removed: { names in "The following machines are no longer available and must not be used: \(names)." }
        )
    )

    /// The `machines` feature flag. Resolved by name so a flag registry without it reads as off.
    static let flag = CoreFlag.Key(rawValue: "machines")

    // parity: core/src/machine/instructions.ts#Interface [status=implemented hash=a6d9a39440d4]
    public protocol Interface: Sendable {
        /// Lists the machines a tool path can name, when the `machines` flag is on.
        func load() async -> Instructions.List
    }

    // parity: core/src/machine/instructions.ts#Service [status=implemented hash=f265d42ad8eb]
    public final class Service: Interface, Sendable {
        public static let serviceKey = "@opencode/MachineInstructions"

        private let flags: any CoreFlag.Interface
        private let machines: any Machines.Interface

        public init(flags: any CoreFlag.Interface, machines: any Machines.Interface) {
            self.flags = flags
            self.machines = machines
        }

        public func load() async -> Instructions.List {
            // Names only: a connection that drops and returns must append nothing; a call on an offline machine says so.
            let names = await machines.list().map(\.id).sorted()
            let enabled: Bool
            if let flag = MachineInstructions.flag {
                enabled = await flags.enabled(flag)
            } else {
                enabled = false
            }
            let observed: Instructions.Observation<[String]> = enabled && !names.isEmpty ? .value(names) : .removed
            return Instructions.make(Instructions.Source.Definition<[String]>(
                key: Instructions.Key(rawValue: "core/machines")!,
                read: { observed },
                renderInitial: { MachineInstructions.render($0) },
                renderChanged: { previous, current in MachineInstructions.update(previous, current) },
                renderRemoved: { _ in "Other machines are no longer available. Do not use any previously listed machine." }
            ))
        }
    }

    // parity: core/src/machine/instructions.ts#node [status=implemented hash=ade8e68e8192]
    public static let node: LayerNode.Provider = AppNode.makeLocationNode(
        Service.serviceKey,
        LayerNode.ExecutableLayer { deps, _ in
            guard let flags = deps.get(CoreFlag.Service.serviceKey, as: (any CoreFlag.Interface).self),
                  let machines = deps.get(Machines.Service.serviceKey, as: (any Machines.Interface).self)
            else {
                throw Machines.MachineDependencyMissing(service: Service.serviceKey)
            }
            return LayerNode.Output([Service.serviceKey: Service(flags: flags, machines: machines) as any Interface])
        },
        [CoreFlag.node, Machines.node]
    )
}

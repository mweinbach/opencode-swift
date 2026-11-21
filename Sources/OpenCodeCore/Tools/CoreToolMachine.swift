import OpenCodeSchema

// MARK: - MachineTools (`core/src/tool/plugin/machine.ts`)

extension CoreTool {
    public enum MachineTools {
        public struct ListOutput: Equatable, Hashable, Sendable, Codable {
            public let machines: [Machines.Info]

            public init(machines: [Machines.Info]) {
                self.machines = machines
            }
        }

        // parity: core/src/tool/plugin/machine.ts#Plugin [status=adapted hash=a8d8c82853b7]
        public static let Plugin = ToolPluginDescriptor(id: "opencode.tool.machine") { editor, env in
            guard env.machinesEnabled else { return }

            // Registered even with no machines, so adding the first one mid-session leaves the tool catalog as it was.
            editor.namespace(ToolSchema.Namespace(
                name: "machine",
                description: "The other computers this server can work on. See which machines exist and which are connected, to pick one or to run the same thing on several. Use a machine by naming it in a path, such as `gpu:~/project`, for the file tools or as the shell tool's workdir."
            ))
            editor.add(RegisteredTool(
                name: "list",
                description: "List the machines: each one's name (`id`), whether it is connected (`online`), whether it has joined (`paired`, false while it is still waiting to join), and its system and chip (`os`, `arch`) while it is connected.",
                inputSchema: ["type": .string("object"), "properties": .object([:])],
                outputSchema: [
                    "type": .string("object"),
                    "properties": .object(["machines": .object(["type": .string("array")])]),
                    "required": .array([.string("machines")]),
                ],
                options: ToolSchema.Options(namespace: "machine", codemode: true)
            ) { _, _ in
                let list = await env.machines?.list() ?? []
                return ToolSchema.Result(output: encodeToolJSON(ListOutput(machines: list)))
            })
        }
    }
}

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import OpenCodeSchema

// MARK: - AutomationShell (`core/src/automation/shell.ts`)

public enum CoreAutomationShell {
    /// Runs in the creating Session's Location while the user is present: asks once for the shell command's
    /// permissions with `once: true` (no save patterns), so approval applies only to the command stored in this
    /// automation.
    // parity: core/src/automation/shell.ts#authorize [status=implemented hash=1a4b09d03909]
    public static func authorize(
        owner: SessionSchema.Info,
        name: String,
        trigger: AutomationSchema.Trigger,
        action: AutomationSchema.ShellAction,
        invocation: CoreAutomation.Author.Invocation? = nil,
        agents: any CoreAgent.Agent.Interface,
        shellSelect: any CoreShell.Select.Interface,
        environment: any CoreLocation.Environment.Interface,
        fileAccess: any CoreFilesystem.FileAccess.Interface,
        permission: any CorePermission.Interface,
        awaitPluginActivation: @Sendable () async -> Void = {}
    ) async throws {
        if invocation != nil {
            await awaitPluginActivation()
        }
        let selected = await agents.select(owner.agent.map(AgentSchema.ID.init(rawValue:)))
        if let invocation, !CoreAutomation.Author.matchesAuthor(ownerSessionID: owner.id, agent: selected.info, invocation: invocation) {
            throw CoreAutomation.InvalidError(reason: "Create the automation with the session's current agent")
        }
        let program = await shellSelect.resolve(CoreShell.Select.ResolveInput(priority: .compat))
        let target: CoreFilesystem.FileAccess.Target
        do {
            target = try await fileAccess.resolve(CoreFilesystem.FileAccess.ResolveInput(
                path: ".",
                kind: .directory,
                base: CoreFilesystem.FileAccess.Place(
                    absolute: owner.location.directory,
                    environment: environment.id
                )
            ))
        } catch let error as CoreAutomation.InvalidError {
            throw error
        } catch {
            throw CoreAutomation.InvalidError(reason: String(describing: error))
        }

        let requests: [CoreFilesystem.FileAccess.PermissionRequest]
        do {
            requests = try await CoreShellPermissions.requests(
                access: fileAccess,
                input: CoreShellPermissions.RequestInput(
                    command: action.command,
                    program: program,
                    target: target,
                    local: true,
                    once: true
                )
            )
        } catch let error as CoreAutomation.InvalidError {
            throw error
        } catch {
            throw CoreAutomation.InvalidError(reason: String(describing: error))
        }

        let encoder = JSONEncoder()
        let triggerValue: JSONValue = (try? JSONDecoder().decode(JSONValue.self, from: encoder.encode(trigger))) ?? .null
        let metadata: [String: JSONValue] = [
            "automation": .string(name),
            "trigger": triggerValue,
            "unattended": .bool(true),
            "command": .string(action.command),
        ]

        // No save patterns: approval applies only to the command stored in this automation.
        for request in requests {
            try await permission.assert(CorePermission.AssertInput(
                sessionID: invocation?.sessionID ?? owner.id,
                agent: invocation?.agent ?? selected.id,
                action: request.action,
                resources: request.resources,
                save: request.save,
                metadata: metadata,
                source: invocation?.source
            ))
        }
    }

    /// Approved once at creation (see `authorize`); runs intentionally don't recheck permissions. Pause or delete to
    /// stop future runs. Returns an async closure that waits for the shell result and stops the shell on cancellation.
    // parity: core/src/automation/shell.ts#start [status=implemented hash=4926e1fbf090]
    public static func start(
        owner: SessionSchema.Info,
        action: AutomationSchema.ShellAction,
        directory: String,
        shell: any CoreShell.Interface,
        shellSelect: any CoreShell.Select.Interface,
        awaitPluginActivation: @Sendable () async -> Void = {}
    ) async throws -> @Sendable () async -> CoreShell.ResultHelper.Result {
        await awaitPluginActivation()
        let program = await shellSelect.resolve(CoreShell.Select.ResolveInput(priority: .compat))
        let info = try await shell.create(
            CoreShell.CreateRequest(
                command: action.command,
                cwd: directory,
                shell: program,
                metadata: ["sessionID": .string(owner.id.rawValue)]
            ),
            before: { input in
                // Hooks can set the environment, but the stored command and its working directory are fixed.
                input.command = action.command
                input.cwd = directory
                input.shell = program
                input.timeout = 0
            }
        )
        return {
            await withTaskCancellationHandler {
                await shell.result(info, waitMs: nil)
            } onCancel: {
                Task { _ = try? await shell.stop(info.id, reason: .killed) }
            }
        }
    }
}

extension CoreAutomation {
    public typealias Shell = CoreAutomationShell
}

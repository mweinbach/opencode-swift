// Pure Swift 6 port of keymap/src/services/command-executor.ts.

// MARK: - Command Execution Types

public enum RunCommandFailureReason: String, Equatable, Hashable, Sendable {
    case notFound = "not-found"
    case inactive
    case disabled
    case invalidArgs = "invalid-args"
    case rejected
    case error
}

public struct RunCommandResult<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let ok: Bool
    public let reason: RunCommandFailureReason?
    public let command: Command<Target, Event>?

    public init(
        ok: Bool,
        reason: RunCommandFailureReason? = nil,
        command: Command<Target, Event>? = nil
    ) {
        self.ok = ok
        self.reason = reason
        self.command = command
    }

    public static func success(command: Command<Target, Event>? = nil) -> RunCommandResult<Target, Event> {
        RunCommandResult(ok: true, reason: nil, command: command)
    }

    public static func failure(
        _ reason: RunCommandFailureReason,
        command: Command<Target, Event>? = nil
    ) -> RunCommandResult<Target, Event> {
        RunCommandResult(ok: false, reason: reason, command: command)
    }
}

public struct RunCommandOptions<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public var event: Event?
    /// `.none` resolves the current host focused target; `.some(nil)` forces unfocused; `.some(target)` forces `target`.
    public var focused: Target??
    public var target: Target??
    public var includeCommand: Bool
    public var payload: KeymapValue?

    public init(
        event: Event? = nil,
        focused: Target?? = nil,
        target: Target?? = nil,
        includeCommand: Bool = false,
        payload: KeymapValue? = nil
    ) {
        self.event = event
        self.focused = focused
        self.target = target
        self.includeCommand = includeCommand
        self.payload = payload
    }
}

public struct CommandExecutorOptions<Target: Hashable & Sendable, Event: KeymapEvent>: Sendable {
    public let createCommandEvent: @Sendable () -> Event

    public init(createCommandEvent: @escaping @Sendable () -> Event) {
        self.createCommandEvent = createCommandEvent
    }
}

// MARK: - Command Executor Service

// parity: keymap/src/services/command-executor.ts#CommandExecutorService [status=implemented hash=065748ec91e9]
public protocol CommandExecutorService<Target, Event>: AnyObject, Sendable {
    associatedtype Target: Hashable & Sendable
    associatedtype Event: KeymapEvent

    func runCommand(_ cmd: String, options: RunCommandOptions<Target, Event>?) -> RunCommandResult<Target, Event>
    func dispatchCommand(_ cmd: String, options: RunCommandOptions<Target, Event>?) -> RunCommandResult<Target, Event>
    func runBinding(
        layer: RegisteredLayer<Target, Event>,
        binding: BindingState<Target, Event>,
        event: Event,
        focused: Target?,
        payload: KeymapValue?
    ) -> Bool
}

private enum ExecutionOutcomeStatus {
    case handled
    case rejected
    case error
}

private enum ProgrammaticExecutionMode {
    case registered
    case active
}

public final class DefaultCommandExecutorService<Target: Hashable & Sendable, Event: KeymapEvent>:
    CommandExecutorService, @unchecked Sendable
{
    private let notify: KeymapNotifier
    private let runtime: any RuntimeService
    private let activation: any ActivationService<Target, Event>
    private let catalog: any CommandCatalogService<Target, Event>
    private let options: CommandExecutorOptions<Target, Event>

    public init(
        notify: KeymapNotifier,
        runtime: any RuntimeService,
        activation: any ActivationService<Target, Event>,
        catalog: any CommandCatalogService<Target, Event>,
        options: CommandExecutorOptions<Target, Event>
    ) {
        self.notify = notify
        self.runtime = runtime
        self.activation = activation
        self.catalog = catalog
        self.options = options
    }

    public func runCommand(
        _ cmd: String,
        options commandOptions: RunCommandOptions<Target, Event>? = nil
    ) -> RunCommandResult<Target, Event> {
        executeProgrammaticCommand(cmd, commandOptions: commandOptions, mode: .registered)
    }

    public func dispatchCommand(
        _ cmd: String,
        options commandOptions: RunCommandOptions<Target, Event>? = nil
    ) -> RunCommandResult<Target, Event> {
        executeProgrammaticCommand(cmd, commandOptions: commandOptions, mode: .active)
    }

    public func runBinding(
        layer bindingLayer: RegisteredLayer<Target, Event>,
        binding: BindingState<Target, Event>,
        event: Event,
        focused: Target?,
        payload: KeymapValue? = nil
    ) -> Bool {
        let data = runtime.getReadonlyData()

        if let run = binding.run {
            let label = binding.command?.commandName ?? "<function>"
            let executed = executeHandler(
                commandName: label,
                commandView: nil,
                run: run,
                context: CommandContext(
                    event: event,
                    focused: focused,
                    target: bindingLayer.target,
                    data: data,
                    input: label,
                    payload: payload
                ),
                includeCommand: false
            )
            if executed.status == .rejected {
                return false
            }
            applyBindingEventEffects(binding, event: event)
            return true
        }

        guard let commandName = binding.command?.commandName else {
            return false
        }

        let execution: CommandExecutionFields? =
            payload.map { CommandExecutionFields(input: commandName, payload: $0) }
        let chain = catalog.getResolvedCommandChain(
            commandName,
            focused: focused,
            execution: execution
        ).entries

        for entry in chain ?? [] {
            let executed = executeHandler(
                commandName: commandName,
                commandView: entry.command,
                run: entry.command.run,
                context: CommandContext(
                    event: event,
                    focused: focused,
                    target: entry.target ?? bindingLayer.target,
                    data: data,
                    input: entry.input ?? commandName,
                    payload: entry.payload
                ),
                includeCommand: false
            )
            if executed.status == .rejected {
                continue
            }

            applyBindingEventEffects(binding, event: event)
            return true
        }

        return false
    }

    // MARK: - Internal Execution Helpers

    private func executeHandler(
        commandName: String,
        commandView: Command<Target, Event>?,
        run: CommandHandler<Target, Event>,
        context: CommandContext<Target, Event>,
        includeCommand: Bool
    ) -> (status: ExecutionOutcomeStatus, result: RunCommandResult<Target, Event>) {
        let resultCommand = includeCommand ? commandView : nil
        let rawResult: Bool?
        do {
            rawResult = try run(context)
        } catch {
            notify.emitError(
                "command-execution-error",
                error: error,
                message: "[Keymap] Error running command \"\(commandName)\":"
            )
            return (.error, .failure(.error, command: resultCommand))
        }

        if rawResult == false {
            return (.rejected, .failure(.rejected, command: resultCommand))
        }

        return (.handled, .success(command: resultCommand))
    }

    private func executeCommandChain(
        commandName: String,
        chain: [ResolvedCommandEntry<Target, Event>]?,
        event: Event,
        focused: Target?,
        targetOverride: Target??,
        data: EventData,
        payload: KeymapValue?,
        includeCommand: Bool
    ) -> (done: RunCommandResult<Target, Event>?, rejected: RunCommandResult<Target, Event>?) {
        var rejected: RunCommandResult<Target, Event>?
        for entry in chain ?? [] {
            let resolvedTarget: Target?
            if let explicitTarget = targetOverride {
                resolvedTarget = explicitTarget
            } else {
                resolvedTarget = entry.target
            }

            let executed = executeHandler(
                commandName: commandName,
                commandView: entry.command,
                run: entry.command.run,
                context: CommandContext(
                    event: event,
                    focused: focused,
                    target: resolvedTarget,
                    data: data,
                    input: commandName,
                    payload: payload
                ),
                includeCommand: includeCommand
            )

            if executed.status == .handled || executed.status == .error {
                return (executed.result, rejected)
            }
            rejected = executed.result
        }

        return (nil, rejected)
    }

    private func executeProgrammaticCommand(
        _ cmd: String,
        commandOptions: RunCommandOptions<Target, Event>?,
        mode: ProgrammaticExecutionMode
    ) -> RunCommandResult<Target, Event> {
        let normalizedCommand: BindingCommand<Target, Event>?
        do {
            normalizedCommand = try normalizeBindingCommand(.named(cmd))
        } catch {
            return .failure(.invalidArgs)
        }

        guard let normalized = normalizedCommand?.commandName else {
            return .failure(.notFound)
        }

        let includeCommand = commandOptions?.includeCommand == true
        let focused: Target?
        if let explicitFocused = commandOptions?.focused {
            focused = explicitFocused
        } else {
            focused = activation.getFocusedTargetIfAvailable()
        }
        let event = commandOptions?.event ?? options.createCommandEvent()
        let data = runtime.getReadonlyData()
        let payload = commandOptions?.payload

        let chain: [ResolvedCommandEntry<Target, Event>]?
        switch mode {
        case .registered:
            chain = catalog.getRegisteredResolvedEntries(normalized)
        case .active:
            chain = catalog.getActiveRegisteredResolvedEntries(normalized, focused: focused)
        }

        let (done, rejected) = executeCommandChain(
            commandName: normalized,
            chain: chain,
            event: event,
            focused: focused,
            targetOverride: commandOptions?.target,
            data: data,
            payload: payload,
            includeCommand: includeCommand
        )
        if let done {
            return done
        }

        var rejectedResult = rejected
        let execFields = CommandExecutionFields(input: normalized, payload: payload)
        let fallback: ResolvedCommandLookup<Target, Event>
        switch mode {
        case .registered:
            fallback = catalog.resolveRegisteredResolverFallback(normalized, execution: execFields)
        case .active:
            fallback = catalog.resolveActiveResolverFallback(normalized, focused: focused, execution: execFields)
        }

        if let resolved = fallback.resolved {
            let resolvedTarget: Target?
            if let explicitTarget = commandOptions?.target {
                resolvedTarget = explicitTarget
            } else {
                resolvedTarget = resolved.target
            }

            let executed = executeHandler(
                commandName: normalized,
                commandView: resolved.command,
                run: resolved.command.run,
                context: CommandContext(
                    event: event,
                    focused: focused,
                    target: resolvedTarget,
                    data: data,
                    input: resolved.input ?? normalized,
                    payload: resolved.payload
                ),
                includeCommand: includeCommand
            )

            if executed.status == .handled || executed.status == .error {
                return executed.result
            }
            rejectedResult = executed.result
        }

        if fallback.hadError {
            return .failure(.error)
        }

        if mode == .active,
            let unavailable = catalog.getDispatchUnavailableCommandState(
                normalized,
                focused: focused,
                includeCommand: includeCommand
            )
        {
            let reason: RunCommandFailureReason = unavailable.reason == .disabled ? .disabled : .inactive
            return .failure(reason, command: unavailable.command)
        }

        return rejectedResult ?? .failure(.notFound)
    }
}

private func applyBindingEventEffects<Target: Hashable & Sendable, Event: KeymapEvent>(
    _ binding: BindingState<Target, Event>,
    event: Event
) {
    if !binding.preventDefault {
        return
    }
    event.preventDefault()
    event.stopPropagation()
}

// parity: keymap/src/services/command-executor.ts#createCommandExecutorService [status=implemented hash=5abe82e30dd3]
public func createCommandExecutorService<Target: Hashable & Sendable, Event: KeymapEvent>(
    notify: KeymapNotifier,
    runtime: any RuntimeService,
    activation: any ActivationService<Target, Event>,
    catalog: any CommandCatalogService<Target, Event>,
    options: CommandExecutorOptions<Target, Event>
) -> DefaultCommandExecutorService<Target, Event> {
    DefaultCommandExecutorService(
        notify: notify,
        runtime: runtime,
        activation: activation,
        catalog: catalog,
        options: options
    )
}

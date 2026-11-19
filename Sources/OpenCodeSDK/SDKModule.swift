import OpenCodeClient
import OpenCodeCore
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeServer
import OpenCodeUtil

/// Entry module for `OpenCodeSDK` (port of `packages/sdk`: composes `OpenCodeClient`,
/// `OpenCodeCore`, and `OpenCodeServer` into an in-process Promise, Effect, and Workerd host).
public enum OpenCodeSDKModule {
    public static let upstreamPackage = "sdk"
    public static let serverPackage = OpenCodeServerModule.upstreamPackage
}

// MARK: - Canonical Schema Contracts (`packages/sdk/src/contracts.ts`)

/// Re-exports canonical schema contracts directly from `OpenCodeSchema` so SDK consumers share
/// identical domain types with Core, Protocol, Client, and Server (`packages/sdk/src/contracts.ts`).
public enum SDKContracts {
    public typealias Agent = AgentSchema
    public typealias Command = CommandSchema
    public typealias Config = ConfigSchema
    public typealias Credential = CredentialSchema
    public typealias Event = EventSchema
    public typealias FileSystem = FileSystemSchema
    public typealias Integration = IntegrationSchema
    public typealias Location = LocationSchema
    public typealias Model = ModelSchema
    public typealias Permission = PermissionSchema
    public typealias PermissionSaved = PermissionSavedSchema
    public typealias Project = ProjectSchema
    public typealias Worktree = WorktreeSchema
    public typealias Prompt = PromptSchema
    public typealias PromptInput = PromptInputSchema
    public typealias Provider = ProviderSchema
    public typealias Pty = PtySchema
    public typealias Question = QuestionSchema
    public typealias Reference = ReferenceSchema
    public typealias WebSearch = WebSearchSchema
    public typealias AbsolutePath = SchemaPrimitive.AbsolutePath
    public typealias RelativePath = SchemaPrimitive.RelativePath
    public typealias Session = SessionSchema
    public typealias SessionInbox = SessionInboxSchema
    public typealias SessionMessage = SessionMessageSchema
    public typealias Skill = SkillSchema
    public typealias Workspace = WorkspaceSchema
}

// MARK: - Tool Contract Re-exports (`packages/sdk/src/tool.ts` & `packages/sdk/src/effect/tool.ts`)

/// Promise-surface tool contract re-exports (`packages/sdk/src/tool.ts`).
public enum SDKTool {
    public typealias RegistrationError = CoreTool.RegistrationError
    public typealias Error = ToolSchema.ToolError
    public typealias Context = PluginPromise.ToolContext
    public typealias Info = PluginPromise.Info
}

/// Effect-surface tool contract re-exports (`packages/sdk/src/effect/tool.ts`).
public enum SDKEffectTool {
    public typealias RegistrationError = CoreTool.RegistrationError
    public typealias Error = ToolSchema.ToolError
    public typealias Context = ToolSchema.Context
    public typealias Info<
        Input: Sendable,
        Output: Equatable & Hashable & Sendable & Codable
    > = ToolSchema.Info<Input, Output>
}

// MARK: - Top-Level Entry Re-exports (`packages/sdk/src/index.ts` & `packages/sdk/src/effect/index.ts`)

/// Re-export of Promise `ClientError` (`packages/sdk/src/index.ts`).
public typealias SDKClientError = ClientError

/// Re-export of canonical `OpenCodeEvent` (`packages/sdk/src/index.ts`).
public typealias SDKOpenCodeEvent = OpenCodeProtocol.OpenCodeEvent

/// Effect-native SDK entrypoint surface (`packages/sdk/src/effect/index.ts`).
public enum EffectSDK {
    public typealias OpenCode = OpenCodeEffect
    public typealias Workerd = OpenCodeEffectWorkerd
    public typealias Tool = SDKEffectTool
    public typealias EnvironmentDriver = CoreLocation.Environment.Driver
    public typealias EnvironmentFiles = CoreLocation.Environment.Files
    public typealias WorkspaceDriver = CoreProject.Workspace.Driver
    public typealias ClientError = EffectClient.ClientError
    public typealias OpenCodeEvent = OpenCodeProtocol.OpenCodeEvent
    public typealias Contracts = SDKContracts
}

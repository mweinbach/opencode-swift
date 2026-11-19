/// Core wire-compatible schema placeholders for progressive porting of `packages/schema`.
/// Each model will be filled out with full field parity and differential JSON round-trip vectors.
public struct OpenCodeLocation: Equatable, Hashable, Sendable, Codable {
    public let directory: String
    public let workspaceID: WorkspaceID?

    public init(directory: String, workspaceID: WorkspaceID? = nil) {
        self.directory = directory
        self.workspaceID = workspaceID
    }
}

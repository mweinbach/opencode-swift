import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema

/// Entry module for `OpenCodeClient` (port of `packages/client`: typed HTTP/SSE/WS client
/// and background service discovery). Depends only on Schema, Protocol, and Platform — never Core or Server.
public enum OpenCodeClientModule {
    public static let upstreamPackage = "client"
}

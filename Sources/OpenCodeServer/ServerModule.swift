import OpenCodeCore
import OpenCodePlatform
import OpenCodeProtocol
import OpenCodeSchema
import OpenCodeUtil

/// Entry module for `OpenCodeServer` (port of `packages/server`: HTTP/SSE/WS handlers,
/// auth, CORS, event feed, pairing, and location routing).
public enum OpenCodeServerModule {
    public static let upstreamPackage = "server"
}

/// Standalone cross-platform Swift 6.2 port of `@opentunnel/client`.
public enum OpenTunnelClientModule {
    /// Ported `@opentunnel/client` specification version.
    public static let version = "0.6.1"

    /// Default OpenTunnel hosted API endpoint (overridable via `OPENTUNNEL_API`).
    public static let defaultAPIURL = "https://opentunnel.xyz"

    /// `User-Agent` header sent on OpenTunnel API calls and bridge WebSocket handshakes.
    public static let userAgent = "opentunnel-sdk/\(version)"

    /// Default profile name shared across the OpenTunnel CLI and SDK.
    public static let defaultProfile = "default"
}

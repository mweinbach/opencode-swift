import OpenCodeClient
import OpenCodeCore
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeServer
import OpenCodeTUI
import OpenCodeUtil

@main
struct OpenCodeCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "--version", "-v", "version":
            print("swift-opencode 0.1.0-dev (\(Platform.current.rawValue))")
        case "platform", "debug":
            let caps = Platform.capabilities
            let roots = GlobalPaths.roots()
            print("platform: \(Platform.current.rawValue)")
            print("capabilities: subprocesses=\(caps.supportsSubprocesses) pty=\(caps.supportsPTY) server=\(caps.supportsLocalHTTPServer) tui=\(caps.supportsTerminalUI)")
            print("paths.data:   \(roots.data)")
            print("paths.cache:  \(roots.cache)")
            print("paths.config: \(roots.config)")
            print("paths.state:  \(roots.state)")
            print("paths.tmp:    \(roots.tmp)")
        default:
            print(
                """
                swift-opencode (bootstrap)
                Platform: \(Platform.current.rawValue)

                Usage:
                  opencode --version     Show build and platform info
                  opencode debug         Show detected platform capabilities and XDG paths
                """
            )
        }
    }
}

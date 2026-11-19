/// Native SwiftUI cross-Apple-platform OpenCode application library.
public enum OpenCodeAppModule {
    public static let name = "OpenCode"
    public static let version = "0.1.0"
}

#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import SwiftUI

/// Entry launcher invoked by the `opencode-app` executable (`Sources/OpenCodeAppMain/main.swift`).
public enum OpenCodeAppLauncher {
    @MainActor
    public static func launch() {
        OpenCodeSwiftUIApp.main()
    }
}
#endif

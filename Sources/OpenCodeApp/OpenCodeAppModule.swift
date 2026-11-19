/// Native SwiftUI cross-Apple-platform OpenCode application library.
public enum OpenCodeAppModule {
    public static let name = "OpenCode"
}

#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
public enum OpenCodeAppLauncher {
    public static func launch() {}
}
#endif

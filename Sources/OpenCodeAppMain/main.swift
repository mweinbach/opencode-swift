import OpenCodeApp

#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import SwiftUI

@main
struct OpenCodeDesktopEntrypoint {
    static func main() {
        OpenCodeAppLauncher.launch()
    }
}
#else
@main
struct OpenCodeDesktopEntrypoint {
    static func main() {
        print("OpenCode SwiftUI app requires an Apple OS with SwiftUI support.")
    }
}
#endif

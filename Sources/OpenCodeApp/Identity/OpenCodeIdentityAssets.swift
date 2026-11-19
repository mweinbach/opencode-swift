import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Bundled upstream OpenCode brand identity assets (`upstream/opencode/packages/identity/`).
public enum OpenCodeIdentityAssets {
    /// Enumeration of every bundled OpenCode identity asset in `Resources/Identity/`.
    public enum Asset: String, CaseIterable, Equatable, Hashable, Sendable {
        case markSVG = "mark.svg"
        case markLightSVG = "mark-light.svg"
        case mark96PNG = "mark-96x96.png"
        case mark192PNG = "mark-192x192.png"
        case mark512PNG = "mark-512x512.png"
        case mark512LightPNG = "mark-512x512-light.png"

        public var resourceName: String {
            switch self {
            case .markSVG: return "mark"
            case .markLightSVG: return "mark-light"
            case .mark96PNG: return "mark-96x96"
            case .mark192PNG: return "mark-192x192"
            case .mark512PNG: return "mark-512x512"
            case .mark512LightPNG: return "mark-512x512-light"
            }
        }

        public var fileExtension: String {
            switch self {
            case .markSVG, .markLightSVG: return "svg"
            case .mark96PNG, .mark192PNG, .mark512PNG, .mark512LightPNG: return "png"
            }
        }
    }

    /// Supported PNG icon resolutions bundled in `Resources/Identity/`.
    public enum MarkSize: Int, CaseIterable, Equatable, Hashable, Sendable {
        case px96 = 96
        case px192 = 192
        case px512 = 512
    }

    /// Resolves the bundled URL for `asset` from `Bundle.module`.
    public static func url(for asset: Asset) -> URL? {
        let subdirectories: [String?] = ["Resources/Identity", "Identity", nil]
        for subdirectory in subdirectories {
            if let found = Bundle.module.url(
                forResource: asset.resourceName,
                withExtension: asset.fileExtension,
                subdirectory: subdirectory
            ) {
                return found
            }
        }
        return nil
    }

    /// Loads raw bytes for `asset` from `Bundle.module`.
    public static func data(for asset: Asset) -> Data? {
        guard let fileURL = url(for: asset) else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    /// Loads the UTF-8 SVG source for either the light or dark OpenCode brand mark.
    public static func svgString(lightMode: Bool = false) -> String? {
        let asset: Asset = lightMode ? .markLightSVG : .markSVG
        guard let bytes = data(for: asset) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Loads PNG data for the requested mark resolution and color scheme.
    public static func pngData(size: MarkSize = .px512, lightMode: Bool = false) -> Data? {
        let asset: Asset
        switch size {
        case .px96:
            asset = .mark96PNG
        case .px192:
            asset = .mark192PNG
        case .px512:
            asset = lightMode ? .mark512LightPNG : .mark512PNG
        }
        return data(for: asset)
    }

    #if canImport(AppKit)
    /// Loads the bundled PNG mark as an `NSImage` for macOS window/dock/toolbar chrome.
    public static func nsImage(size: MarkSize = .px512, lightMode: Bool = false) -> NSImage? {
        guard let bytes = pngData(size: size, lightMode: lightMode) else { return nil }
        return NSImage(data: bytes)
    }
    #endif

    #if canImport(UIKit)
    /// Loads the bundled PNG mark as a `UIImage` for iOS, iPadOS, and visionOS surfaces.
    public static func uiImage(size: MarkSize = .px512, lightMode: Bool = false) -> UIImage? {
        guard let bytes = pngData(size: size, lightMode: lightMode) else { return nil }
        return UIImage(data: bytes)
    }
    #endif

    #if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
    /// Loads the bundled PNG mark directly as a SwiftUI `Image`.
    public static func swiftUIImage(size: MarkSize = .px512, lightMode: Bool = false) -> Image? {
        #if canImport(AppKit)
        guard let native = nsImage(size: size, lightMode: lightMode) else { return nil }
        return Image(nsImage: native)
        #elseif canImport(UIKit)
        guard let native = uiImage(size: size, lightMode: lightMode) else { return nil }
        return Image(uiImage: native)
        #else
        return nil
        #endif
    }
    #endif
}

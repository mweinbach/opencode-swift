#if canImport(SwiftUI) && (os(macOS) || os(iOS) || os(visionOS))
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Cross-Apple clipboard utility (macOS `NSPasteboard`, iOS/visionOS `UIPasteboard`).
public enum OpenCodeAppClipboard {
    @MainActor
    public static func copy(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit) && !os(watchOS)
        UIPasteboard.general.string = text
        #endif
    }
}

/// Renders the official OpenCode identity mark using the bundled PNG assets from
/// `Sources/OpenCodeApp/Resources/Identity/` with an exact-geometry vector fallback
/// matching `mark.svg` and `mark-light.svg`.
public struct OpenCodeBrandMarkView: View {
    public let size: CGFloat
    public let isLight: Bool
    public let cornerRadius: CGFloat

    public init(size: CGFloat = 28, isLight: Bool = false, cornerRadius: CGFloat? = nil) {
        self.size = size
        self.isLight = isLight
        self.cornerRadius = cornerRadius ?? max(4, size * 0.2)
    }

    public var body: some View {
        Group {
            if let bundled = OpenCodeIdentityAssets.swiftUIImage(size: .px512, lightMode: isLight) {
                bundled
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                vectorMark
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Exact-coordinate vector replica of `upstream/opencode/packages/identity/mark.svg`.
    private var vectorMark: some View {
        Canvas { context, canvasSize in
            let scaleX = canvasSize.width / 512.0
            let scaleY = canvasSize.height / 512.0

            let bgColor = isLight
                ? Color(.sRGB, red: 0.992, green: 0.988, blue: 0.988, opacity: 1)
                : Color(.sRGB, red: 0.075, green: 0.063, blue: 0.063, opacity: 1)
            let innerFill = isLight
                ? Color(.sRGB, red: 0.902, green: 0.898, blue: 0.902, opacity: 1)
                : Color(.sRGB, red: 0.353, green: 0.345, blue: 0.345, opacity: 1)
            let frameFill = isLight
                ? Color(.sRGB, red: 0.090, green: 0.094, blue: 0.110, opacity: 1)
                : Color.white

            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(bgColor))

            let innerRect = CGRect(x: 192 * scaleX, y: 224 * scaleY, width: 128 * scaleX, height: 128 * scaleY)
            context.fill(Path(innerRect), with: .color(innerFill))

            var outer = Path()
            outer.addRect(CGRect(x: 128 * scaleX, y: 96 * scaleY, width: 256 * scaleX, height: 320 * scaleY))
            outer.addRect(CGRect(x: 192 * scaleX, y: 160 * scaleY, width: 128 * scaleX, height: 192 * scaleY))
            context.fill(outer, with: .color(frameFill), style: FillStyle(eoFill: true))
        }
    }
}

/// Live status dot/badge for sidebar sessions (`working`, `blocked`, `retrying`, `idle`).
public struct SessionStatusBadgeView: View {
    public let badge: AppSessionStatusBadge
    public let palette: AppResolvedPalette

    public init(badge: AppSessionStatusBadge, palette: AppResolvedPalette) {
        self.badge = badge
        self.palette = palette
    }

    public var body: some View {
        switch badge {
        case .idle:
            Circle()
                .fill(palette.textFaintColor.opacity(0.45))
                .frame(width: 7, height: 7)
                .accessibilityLabel("Idle")
        case .working:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
                .accessibilityLabel("Working")
        case .retrying:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(palette.warningColor)
                .accessibilityLabel("Retrying")
        case let .blocked(permissions, forms):
            let total = permissions + forms
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                if total > 1 {
                    Text("\(total)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                }
            }
            .foregroundStyle(palette.warningColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(palette.warningColor.opacity(0.15), in: Capsule())
            .accessibilityLabel(badge.accessibilityLabel)
        }
    }
}
#endif

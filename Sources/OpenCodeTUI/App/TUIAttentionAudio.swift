#if os(WASI)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#else
import Foundation
#endif
import Synchronization
import OpenCodeCore
import OpenCodePlatform

/// Cross-platform bundled MP3 asset resolution, binary validation, and non-blocking native audio playback
/// for TUI attention notifications.
public enum TUIAttentionAudio {
    /// The 5 built-in attention sound assets bundled in `OpenCodeTUI/Resources/Audio`.
    public enum SoundKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case `default`
        case question
        case permission
        case error
        case subagentDone = "subagent_done"

        /// Exact filename of the bundled `.mp3` asset.
        public var filename: String {
            switch self {
            case .default: return "bip-bop-01.mp3"
            case .question: return "bip-bop-03.mp3"
            case .permission: return "staplebops-06.mp3"
            case .error: return "nope-03.mp3"
            case .subagentDone: return "yup-01.mp3"
            }
        }

        /// Resource stem without extension (for `Bundle.url(forResource:withExtension:)`).
        public var resourceName: String {
            switch self {
            case .default: return "bip-bop-01"
            case .question: return "bip-bop-03"
            case .permission: return "staplebops-06"
            case .error: return "nope-03"
            case .subagentDone: return "yup-01"
            }
        }

        /// File extension of the bundled resource.
        public var resourceExtension: String { "mp3" }

        /// Upstream logical asset identifier (`@opencode/ui/audio/<filename>`).
        public var upstreamAssetKey: String {
            "@opencode/ui/audio/\(filename)"
        }

        /// Maps an upstream `PluginTui.AttentionSoundName` (including `.done -> .default`) to its bundled asset kind.
        public init(soundName: PluginTui.AttentionSoundName) {
            switch soundName {
            case .default, .done: self = .default
            case .question: self = .question
            case .permission: self = .permission
            case .error: self = .error
            case .subagentDone: self = .subagentDone
            }
        }

        /// Resolves a `SoundKind` from a bare filename (`bip-bop-01.mp3`) or upstream key (`@opencode/ui/audio/bip-bop-01.mp3`).
        public static func from(filenameOrKey value: String) -> SoundKind? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            for kind in Self.allCases {
                if trimmed == kind.filename || trimmed == kind.upstreamAssetKey {
                    return kind
                }
            }
            return nil
        }
    }

    /// Priority-ordered Linux/POSIX audio playback utilities probed at runtime.
    public enum LinuxPlayer: String, CaseIterable, Equatable, Hashable, Sendable {
        case paplay
        case pwPlay = "pw-play"
        case ffplay
        case mpg123
        case aplay
    }

    /// Result of validating MP3 binary headers (ID3v2 tag and MPEG audio frame sync).
    public struct MP3Inspection: Equatable, Hashable, Sendable {
        public let byteCount: Int
        public let hasID3v2Header: Bool
        public let id3MajorVersion: UInt8?
        public let mpegFrameOffset: Int?
        public let hasMPEGFrameSync: Bool

        public init(
            byteCount: Int,
            hasID3v2Header: Bool,
            id3MajorVersion: UInt8?,
            mpegFrameOffset: Int?,
            hasMPEGFrameSync: Bool
        ) {
            self.byteCount = byteCount
            self.hasID3v2Header = hasID3v2Header
            self.id3MajorVersion = id3MajorVersion
            self.mpegFrameOffset = mpegFrameOffset
            self.hasMPEGFrameSync = hasMPEGFrameSync
        }

        public var isValid: Bool {
            byteCount > 0 && hasMPEGFrameSync
        }
    }

    /// Reason native audio playback was intentionally suppressed without error.
    public enum SuppressionReason: String, Equatable, Hashable, Sendable {
        case muted
        case zeroVolume = "zero_volume"
        case headless
        case unsupportedPlatform = "unsupported_platform"
        case missingAsset = "missing_asset"
        case invalidAudioData = "invalid_audio_data"
    }

    /// Outcome of attempting native attention audio playback.
    public enum PlaybackOutcome: Equatable, Hashable, Sendable {
        case played(executable: String, arguments: [String])
        case bellFallback
        case suppressed(SuppressionReason)
        case unavailable(String)

        /// `true` when either native playback was dispatched or the terminal bell fallback fired.
        public var didTriggerFeedback: Bool {
            switch self {
            case .played, .bellFallback: return true
            case .suppressed, .unavailable: return false
            }
        }
    }

    // MARK: - Bundled Resource Resolution (`Bundle.module`)

    #if !os(WASI)
    /// The `OpenCodeTUI` SwiftPM resource bundle (`Bundle.module`).
    public static var resourceBundle: Bundle { .module }

    /// Resolves a bundled `.mp3` resource URL from `bundle` (defaults to `Bundle.module`), checking both
    /// preserved subdirectory layouts (`Resources/Audio`, `Audio`) and flattened bundle lookup.
    public static func bundledSoundURL(
        for kind: SoundKind,
        in bundle: Bundle? = nil
    ) -> URL? {
        bundledSoundURL(forFilename: kind.filename, in: bundle)
    }

    /// Resolves a bundled `.mp3` resource URL for an upstream `PluginTui.AttentionSoundName`.
    public static func bundledSoundURL(
        for soundName: PluginTui.AttentionSoundName,
        in bundle: Bundle? = nil
    ) -> URL? {
        bundledSoundURL(for: SoundKind(soundName: soundName), in: bundle)
    }

    /// Resolves a bundled audio file URL by filename (e.g. `"bip-bop-01.mp3"`), checking
    /// `Resources/Audio`, `Audio`, flattened lookup, and direct `resourceURL` fallbacks.
    public static func bundledSoundURL(
        forFilename filename: String,
        in bundle: Bundle? = nil
    ) -> URL? {
        let targetBundle = bundle ?? .module
        let clean = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains("\\") else {
            return nil
        }

        let (stem, ext) = splitFilename(clean)

        let subdirectories: [String?] = ["Resources/Audio", "Audio", nil]
        for subdir in subdirectories {
            if let url = targetBundle.url(forResource: stem, withExtension: ext, subdirectory: subdir),
               FileManager.default.fileExists(atPath: url.path)
            {
                return url
            }
        }

        if let root = targetBundle.resourceURL {
            let relativeCandidates = [
                "Resources/Audio/\(clean)",
                "Audio/\(clean)",
                clean,
            ]
            for rel in relativeCandidates {
                let candidate = root.appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        return nil
    }
    #endif

    /// Resolves the filesystem path for a bundled `SoundKind`, or `nil` on platforms without resource bundles.
    public static func bundledSoundPath(for kind: SoundKind) -> String? {
        #if os(WASI)
        return nil
        #else
        return bundledSoundURL(for: kind)?.path
        #endif
    }

    /// Resolves the filesystem path for an upstream `PluginTui.AttentionSoundName`.
    public static func bundledSoundPath(for soundName: PluginTui.AttentionSoundName) -> String? {
        bundledSoundPath(for: SoundKind(soundName: soundName))
    }

    /// Resolves the filesystem path for a bundled audio filename (e.g. `"bip-bop-01.mp3"`).
    public static func bundledSoundPath(forFilename filename: String) -> String? {
        #if os(WASI)
        return nil
        #else
        return bundledSoundURL(forFilename: filename)?.path
        #endif
    }

    /// Reads the raw bytes of a bundled sound asset from `Bundle.module`.
    public static func bundledSoundBytes(for kind: SoundKind) -> [UInt8]? {
        #if os(WASI)
        return nil
        #else
        guard let url = bundledSoundURL(for: kind),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return Array(data)
        #endif
    }

    /// Resolves and validates the bundled MP3 bytes for `kind`.
    public static func verifyBundledSound(_ kind: SoundKind) -> MP3Inspection? {
        guard let bytes = bundledSoundBytes(for: kind) else {
            return nil
        }
        return inspectMP3(bytes)
    }

    /// Resolves the asset path for `kind`, honoring `OPENCODE_NODE_ASSETS_DIR` when explicitly set
    /// and otherwise returning the real `Bundle.module` `.mp3` path.
    public static func resolveAssetPath(
        for kind: SoundKind,
        env: any EnvironmentProviding = SystemEnvironment.shared
    ) -> String {
        if let dir = env.variable("OPENCODE_NODE_ASSETS_DIR"), !dir.isEmpty {
            let key = kind.upstreamAssetKey
            return dir.hasSuffix("/") ? "\(dir)\(key)" : "\(dir)/\(key)"
        }
        return bundledSoundPath(for: kind) ?? kind.upstreamAssetKey
    }

    /// Resolves logical keys (`@opencode/ui/audio/bip-bop-01.mp3`) or bare built-in filenames
    /// to their real bundled filesystem path when available; passes through explicit file paths unchanged.
    public static func resolveBundledFilePath(_ pathOrKey: String) -> String {
        if let kind = SoundKind.from(filenameOrKey: pathOrKey),
           let resolved = bundledSoundPath(for: kind)
        {
            return resolved
        }
        if pathOrKey.hasPrefix("@opencode/ui/audio/") {
            let name = String(pathOrKey.dropFirst("@opencode/ui/audio/".count))
            if let resolved = bundledSoundPath(forFilename: name) {
                return resolved
            }
        }
        return pathOrKey
    }

    // MARK: - MP3 Header & Payload Validation

    /// Inspects `bytes` for a valid ID3v2 header and/or MPEG audio frame sync header.
    public static func inspectMP3(_ bytes: [UInt8]) -> MP3Inspection {
        guard bytes.count >= 4 else {
            return MP3Inspection(
                byteCount: bytes.count,
                hasID3v2Header: false,
                id3MajorVersion: nil,
                mpegFrameOffset: nil,
                hasMPEGFrameSync: false
            )
        }

        // Check for ID3v2 header: "ID3" + major (<0xFF) + revision (<0xFF) + flags + 4 synchsafe size bytes (<0x80).
        if bytes.count >= 10,
           bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
           bytes[3] < 0xFF, bytes[4] < 0xFF,
           bytes[6] < 0x80, bytes[7] < 0x80, bytes[8] < 0x80, bytes[9] < 0x80
        {
            let major = bytes[3]
            let hasFooter = (bytes[5] & 0x10) != 0
            let tagSize =
                (Int(bytes[6]) << 21)
                | (Int(bytes[7]) << 14)
                | (Int(bytes[8]) << 7)
                | Int(bytes[9])
            let payloadStart = 10 + tagSize + (hasFooter ? 10 : 0)

            var cursor = payloadStart
            let maxPaddingScan = min(bytes.count, payloadStart + 64)
            while cursor < maxPaddingScan && bytes[cursor] == 0x00 {
                cursor += 1
            }

            if isValidMPEGFrameHeader(bytes, at: cursor) {
                return MP3Inspection(
                    byteCount: bytes.count,
                    hasID3v2Header: true,
                    id3MajorVersion: major,
                    mpegFrameOffset: cursor,
                    hasMPEGFrameSync: true
                )
            }

            return MP3Inspection(
                byteCount: bytes.count,
                hasID3v2Header: true,
                id3MajorVersion: major,
                mpegFrameOffset: nil,
                hasMPEGFrameSync: false
            )
        }

        // Raw MPEG audio stream without ID3v2 tag.
        if isValidMPEGFrameHeader(bytes, at: 0) {
            return MP3Inspection(
                byteCount: bytes.count,
                hasID3v2Header: false,
                id3MajorVersion: nil,
                mpegFrameOffset: 0,
                hasMPEGFrameSync: true
            )
        }

        return MP3Inspection(
            byteCount: bytes.count,
            hasID3v2Header: false,
            id3MajorVersion: nil,
            mpegFrameOffset: nil,
            hasMPEGFrameSync: false
        )
    }

    /// Returns `true` if `bytes` is non-empty and contains a valid MP3 stream (ID3v2 + MPEG frame sync, or raw MPEG sync).
    public static func isValidMP3Data(_ bytes: [UInt8]) -> Bool {
        inspectMP3(bytes).isValid
    }

    /// Validates audio payload bytes for `path`: enforces strict MP3 header validation for `.mp3` files
    /// and non-empty data for other custom user-configured audio formats (e.g. `.wav`, `.aiff`).
    public static func isValidAudioData(_ bytes: [UInt8], path: String) -> Bool {
        guard !bytes.isEmpty else { return false }
        if path.lowercased().hasSuffix(".mp3") {
            return isValidMP3Data(bytes)
        }
        return true
    }

    private static func isValidMPEGFrameHeader(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + 4 <= bytes.count else { return false }
        let b0 = bytes[offset]
        let b1 = bytes[offset + 1]
        let b2 = bytes[offset + 2]

        // 11-bit frame sync: 0xFF followed by top 3 bits set (0xE0)
        guard b0 == 0xFF, (b1 & 0xE0) == 0xE0 else { return false }
        // MPEG version bits (bits 4..3): 01 is reserved
        let versionBits = (b1 >> 3) & 0x03
        guard versionBits != 0x01 else { return false }
        // Layer bits (bits 2..1): 00 is reserved (Layer III = 01)
        let layerBits = (b1 >> 1) & 0x03
        guard layerBits != 0x00 else { return false }
        // Bitrate index (bits 7..4 of byte 2): 1111 is invalid
        let bitrateIndex = (b2 >> 4) & 0x0F
        guard bitrateIndex != 0x0F else { return false }
        // Sample rate index (bits 3..2 of byte 2): 11 is reserved
        let sampleRateIndex = (b2 >> 2) & 0x03
        guard sampleRateIndex != 0x03 else { return false }
        return true
    }

    private static func splitFilename(_ filename: String) -> (stem: String, ext: String?) {
        guard let dot = filename.lastIndex(of: "."), dot != filename.startIndex else {
            return (filename, nil)
        }
        let stem = String(filename[..<dot])
        let ext = String(filename[filename.index(after: dot)...])
        return (stem, ext.isEmpty ? nil : ext)
    }

    // MARK: - Volume, Environment & Command Construction

    /// Clamps a volume value into `[0.0, 1.0]`, treating non-finite values as `0.0`.
    public static func clampVolume(_ volume: Double) -> Double {
        guard volume.isFinite else { return 0 }
        return min(1.0, max(0.0, volume))
    }

    /// Formats a clamped linear gain in `[0.0, 1.0]` deterministically without locale dependence.
    public static func formatGain(_ volume: Double) -> String {
        let clamped = clampVolume(volume)
        let hundredths = Int((clamped * 100.0).rounded())
        if hundredths <= 0 { return "0" }
        if hundredths >= 100 { return "1" }
        if hundredths % 10 == 0 {
            return "0.\(hundredths / 10)"
        }
        if hundredths < 10 {
            return "0.0\(hundredths)"
        }
        return "0.\(hundredths)"
    }

    /// Returns `true` when explicit mute environment flags (`OPENCODE_AUDIO_MUTED`, `OPENCODE_TUI_MUTED`) are set.
    public static func isEnvironmentMuted(_ env: any EnvironmentProviding) -> Bool {
        isTruthy(env.variable("OPENCODE_AUDIO_MUTED"))
            || isTruthy(env.variable("OPENCODE_TUI_MUTED"))
    }

    /// Returns `true` when running in a headless / non-audio environment (`OPENCODE_HEADLESS`,
    /// `OPENCODE_AUDIO_HEADLESS`, `OPENCODE_NO_AUDIO`, `CI`, `TERM=dumb`, or headless Linux SSH).
    public static func isEnvironmentHeadless(
        _ env: any EnvironmentProviding,
        os: PlatformOS = Platform.current
    ) -> Bool {
        if isTruthy(env.variable("OPENCODE_HEADLESS"))
            || isTruthy(env.variable("OPENCODE_AUDIO_HEADLESS"))
            || isTruthy(env.variable("OPENCODE_NO_AUDIO"))
            || isTruthy(env.variable("CI"))
        {
            return true
        }
        if env.variable("TERM")?.lowercased() == "dumb" {
            return true
        }
        if os == .linux || os == .freeBSD {
            let isSSH = !(env.variable("SSH_CONNECTION") ?? "").isEmpty
                || !(env.variable("SSH_TTY") ?? "").isEmpty
            let hasSession = !(env.variable("DISPLAY") ?? "").isEmpty
                || !(env.variable("WAYLAND_DISPLAY") ?? "").isEmpty
                || !(env.variable("PULSE_SERVER") ?? "").isEmpty
                || !(env.variable("PIPEWIRE_RUNTIME_DIR") ?? "").isEmpty
            if isSSH && !hasSession {
                return true
            }
        }
        return false
    }

    /// Builds a terminal BEL (`\u{07}`) fallback closure backed by an injectable writer.
    public static func makeBellFallback(write: @escaping @Sendable (String) -> Void) -> @Sendable () -> Bool {
        {
            write("\u{07}")
            return true
        }
    }

    /// Creates a `PATH`-based executable resolver for `os` and `env`.
    public static func defaultExecutableLookup(
        env: any EnvironmentProviding = SystemEnvironment.shared,
        os: PlatformOS = Platform.current
    ) -> @Sendable (String) -> String? {
        #if os(WASI)
        return { _ in nil }
        #else
        let pathValue = env.variable("PATH")
        let separator: Character = os == .windows ? ";" : ":"
        var directories = (pathValue ?? "")
            .split(separator: separator, omittingEmptySubsequences: true)
            .map(String.init)
        if os != .windows && pathValue == nil {
            for fallbackDir in ["/usr/bin", "/usr/local/bin", "/bin"] where !directories.contains(fallbackDir) {
                directories.append(fallbackDir)
            }
        }
        let capturedDirs = directories
        let isWindows = os == .windows
        return { candidate in
            guard !candidate.isEmpty else { return nil }
            if candidate.contains("/") || candidate.contains("\\") {
                return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
            }
            let names: [String]
            if isWindows && !candidate.lowercased().hasSuffix(".exe") {
                names = [candidate, "\(candidate).exe"]
            } else {
                names = [candidate]
            }
            let sep = isWindows ? "\\" : "/"
            for dir in capturedDirs {
                let prefix = dir.hasSuffix("/") || dir.hasSuffix("\\") ? dir : "\(dir)\(sep)"
                for name in names {
                    let full = "\(prefix)\(name)"
                    if FileManager.default.isExecutableFile(atPath: full) {
                        return full
                    }
                }
            }
            return nil
        }
        #endif
    }

    /// Builds the PowerShell script used on Windows: attempts WPF `System.Windows.Media.MediaPlayer`
    /// (which natively supports `.mp3` and volume control) and falls back to `System.Media.SoundPlayer`.
    public static func windowsPowerShellScript(path: String, volume: Double = 1.0) -> String {
        let escapedPath = path.replacingOccurrences(of: "'", with: "''")
        let gain = formatGain(volume)
        return [
            "$p = '\(escapedPath)'",
            "try {",
            "  Add-Type -AssemblyName PresentationCore -ErrorAction Stop",
            "  $m = New-Object System.Windows.Media.MediaPlayer",
            "  $m.Volume = \(gain)",
            "  $m.Open([Uri]::new($p))",
            "  $m.Play()",
            "  $deadline = [DateTime]::UtcNow.AddSeconds(5)",
            "  while (-not $m.NaturalDuration.HasTimeSpan -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }",
            "  $ms = if ($m.NaturalDuration.HasTimeSpan) { [Math]::Min([int]$m.NaturalDuration.TimeSpan.TotalMilliseconds + 100, 10000) } else { 1500 }",
            "  Start-Sleep -Milliseconds $ms",
            "  $m.Close()",
            "} catch {",
            "  try { (New-Object System.Media.SoundPlayer $p).PlaySync() } catch {}",
            "}",
        ].joined(separator: "; ")
    }

    /// Constructs the OS-specific `ProcessSpec` for playing `path` at optional `volume`.
    /// Returns `nil` for muted/zero volume, unsafe paths, unsupported platforms (iOS/WASI),
    /// or when no audio utility is installed.
    public static func playbackCommand(
        forPath path: String,
        os: PlatformOS = Platform.current,
        volume: Double? = nil,
        executableLookup: (@Sendable (String) -> String?)? = nil
    ) -> ProcessSpec? {
        guard isSafeAudioPath(path) else { return nil }

        let scaledVolume: Double?
        if let volume {
            let clamped = clampVolume(volume)
            guard clamped > 0 else { return nil }
            scaledVolume = clamped < 1.0 ? clamped : nil
        } else {
            scaledVolume = nil
        }

        switch os {
        case .macOS:
            let executable: String
            if let lookup = executableLookup {
                guard let resolved = lookup("/usr/bin/afplay") ?? lookup("afplay") else {
                    return nil
                }
                executable = resolved
            } else {
                executable = "/usr/bin/afplay"
            }
            let args = scaledVolume.map { ["-v", formatGain($0), path] } ?? [path]
            return ProcessSpec(executable: executable, arguments: args)

        case .linux, .freeBSD:
            let lookup = executableLookup ?? defaultExecutableLookup(os: os)
            for player in LinuxPlayer.allCases {
                guard let resolved = lookup(player.rawValue) else { continue }
                let args: [String]
                switch player {
                case .paplay:
                    if let vol = scaledVolume {
                        let paVolume = max(0, min(65_536, Int((vol * 65_536.0).rounded())))
                        args = ["--volume=\(paVolume)", path]
                    } else {
                        args = [path]
                    }
                case .pwPlay:
                    if let vol = scaledVolume {
                        args = ["--volume", formatGain(vol), path]
                    } else {
                        args = [path]
                    }
                case .ffplay:
                    var ffArgs = ["-nodisp", "-autoexit", "-loglevel", "quiet"]
                    if let vol = scaledVolume {
                        let pct = max(0, min(100, Int((vol * 100.0).rounded())))
                        ffArgs.append(contentsOf: ["-volume", "\(pct)"])
                    }
                    ffArgs.append(path)
                    args = ffArgs
                case .mpg123:
                    var mpgArgs = ["-q"]
                    if let vol = scaledVolume {
                        let scale = max(0, min(32_768, Int((vol * 32_768.0).rounded())))
                        mpgArgs.append(contentsOf: ["-f", "\(scale)"])
                    }
                    mpgArgs.append(path)
                    args = mpgArgs
                case .aplay:
                    args = [path]
                }
                return ProcessSpec(executable: resolved, arguments: args)
            }
            return nil

        case .windows:
            let executable: String
            if let lookup = executableLookup {
                guard let resolved = lookup("powershell.exe")
                    ?? lookup("pwsh.exe")
                    ?? lookup("powershell")
                    ?? lookup("pwsh")
                else {
                    return nil
                }
                executable = resolved
            } else {
                executable = "powershell.exe"
            }
            let script = windowsPowerShellScript(path: path, volume: scaledVolume ?? 1.0)
            return ProcessSpec(
                executable: executable,
                arguments: ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command", script]
            )

        case .iOS, .tvOS, .watchOS, .visionOS, .wasi, .android, .unknown:
            return nil
        }
    }

    private static func isSafeAudioPath(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\u{0}") && !path.contains("\r") && !path.contains("\n")
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    // MARK: - Injectable Non-Blocking Native Player

    /// Thread-safe, cross-platform native audio player using an injectable `ProcessSpawner`.
    /// Dispatches playback non-blockingly so the TUI render and input loops never stall.
    public final class Player: Sendable {
        /// Shared default host player.
        public static let shared = Player()

        /// Handle returned immediately from non-blocking playback dispatch.
        public struct PlaybackHandle: Sendable {
            public let outcome: PlaybackOutcome
            private let task: Task<ProcessOutput?, Never>?

            public init(outcome: PlaybackOutcome, task: Task<ProcessOutput?, Never>? = nil) {
                self.outcome = outcome
                self.task = task
            }

            /// Awaits completion of any background subprocess started for this playback.
            @discardableResult
            public func waitForCompletion() async -> ProcessOutput? {
                await task?.value
            }

            /// Cancels the in-flight background subprocess if still running.
            public func cancel() {
                task?.cancel()
            }
        }

        private struct MutableState: Sendable {
            var isMuted: Bool
            var nextTaskID: UInt64 = 1
            var activeTasks: [UInt64: Task<ProcessOutput?, Never>] = [:]
        }

        public let os: PlatformOS
        private let spawner: any ProcessSpawner
        private let env: any EnvironmentProviding
        private let executableLookup: (@Sendable (String) -> String?)?
        private let fileValidator: (@Sendable (String) -> AudioFileStatus)?
        private let headlessDetector: @Sendable (any EnvironmentProviding, PlatformOS) -> Bool
        private let bellFallback: (@Sendable () -> Bool)?
        private let state: Mutex<MutableState>

        /// Result of validating a candidate audio file path on disk.
        public enum AudioFileStatus: Equatable, Hashable, Sendable {
            case valid
            case missing
            case invalidData
        }

        public init(
            os: PlatformOS = Platform.current,
            spawner: any ProcessSpawner = CrossSpawnSpawner.HostProcessSpawner.shared,
            env: any EnvironmentProviding = SystemEnvironment.shared,
            executableLookup: (@Sendable (String) -> String?)? = nil,
            fileValidator: (@Sendable (String) -> AudioFileStatus)? = nil,
            isHeadless: (@Sendable (any EnvironmentProviding, PlatformOS) -> Bool)? = nil,
            muted: Bool = false,
            bellFallback: (@Sendable () -> Bool)? = nil
        ) {
            self.os = os
            self.spawner = spawner
            self.env = env
            self.executableLookup = executableLookup
            self.fileValidator = fileValidator
            self.headlessDetector = isHeadless ?? TUIAttentionAudio.isEnvironmentHeadless
            self.bellFallback = bellFallback
            self.state = Mutex(MutableState(isMuted: muted))
        }

        /// Whether playback is currently muted on this player instance.
        public var isMuted: Bool {
            get { state.withLock { $0.isMuted } }
            set { state.withLock { $0.isMuted = newValue } }
        }

        /// Whether a terminal bell fallback closure is configured.
        public var hasBellFallback: Bool {
            bellFallback != nil
        }

        /// Number of currently running background playback tasks.
        public var activePlaybackCount: Int {
            state.withLock { $0.activeTasks.count }
        }

        /// Cancels all in-flight background playback tasks.
        public func cancelAll() {
            let tasks = state.withLock { s -> [Task<ProcessOutput?, Never>] in
                let list = Array(s.activeTasks.values)
                s.activeTasks.removeAll()
                return list
            }
            for task in tasks {
                task.cancel()
            }
        }

        /// Awaits completion of all currently active background playback tasks.
        public func waitForAll() async {
            let tasks = state.withLock { Array($0.activeTasks.values) }
            for task in tasks {
                _ = await task.value
            }
        }

        /// Validates whether `path` exists and contains valid audio bytes for loading into `TUIAttention`.
        public func validateAudioFile(
            at path: String,
            fileSystem: any OpenCodeFileSystem = LocalFileSystem.shared
        ) async -> AudioFileStatus {
            let resolved = TUIAttentionAudio.resolveBundledFilePath(path)
            guard TUIAttentionAudio.isSafeAudioPath(resolved) else {
                return .missing
            }
            if let customValidator = fileValidator {
                return customValidator(resolved)
            }
            if !PlatformCapabilities.forOS(os).supportsSubprocesses && bellFallback != nil {
                return .valid
            }
            guard let bytes = try? await fileSystem.readFile(at: resolved) else {
                return .missing
            }
            return TUIAttentionAudio.isValidAudioData(bytes, path: resolved) ? .valid : .invalidData
        }

        /// Dispatches native playback of a bundled `SoundKind` without blocking the caller.
        @discardableResult
        public func playNonBlocking(
            kind: SoundKind,
            volume: Double? = nil
        ) -> PlaybackHandle {
            if let suppressed = evaluatePreFlightSuppression(volume: volume) {
                return PlaybackHandle(outcome: suppressed)
            }
            guard let path = TUIAttentionAudio.bundledSoundPath(for: kind) else {
                return PlaybackHandle(outcome: .suppressed(.missingAsset))
            }
            return playNonBlocking(filePath: path, volume: volume)
        }

        /// Dispatches native playback for an upstream `PluginTui.AttentionSoundName` without blocking.
        @discardableResult
        public func playNonBlocking(
            soundName: PluginTui.AttentionSoundName,
            volume: Double? = nil
        ) -> PlaybackHandle {
            playNonBlocking(kind: SoundKind(soundName: soundName), volume: volume)
        }

        /// Dispatches native playback for a file path (or `@opencode/ui/audio/*` key) without blocking.
        /// Never throws; returns a graceful suppression, bell fallback, or unavailable outcome on failure.
        @discardableResult
        public func playNonBlocking(
            filePath: String,
            volume: Double? = nil
        ) -> PlaybackHandle {
            if let suppressed = evaluatePreFlightSuppression(volume: volume) {
                return PlaybackHandle(outcome: suppressed)
            }

            let resolvedPath = TUIAttentionAudio.resolveBundledFilePath(filePath)
            guard TUIAttentionAudio.isSafeAudioPath(resolvedPath) else {
                return PlaybackHandle(outcome: .suppressed(.missingAsset))
            }

            switch validateFileSynchronously(at: resolvedPath) {
            case .valid:
                break
            case .missing:
                return PlaybackHandle(outcome: .suppressed(.missingAsset))
            case .invalidData:
                return PlaybackHandle(outcome: .suppressed(.invalidAudioData))
            }

            let effectiveLookup: (@Sendable (String) -> String?)?
            if let customLookup = executableLookup {
                effectiveLookup = customLookup
            } else if os == Platform.current || os == .linux || os == .freeBSD {
                effectiveLookup = TUIAttentionAudio.defaultExecutableLookup(env: env, os: os)
            } else {
                effectiveLookup = nil
            }

            guard let spec = TUIAttentionAudio.playbackCommand(
                forPath: resolvedPath,
                os: os,
                volume: volume,
                executableLookup: effectiveLookup
            ) else {
                if let bell = bellFallback, bell() {
                    return PlaybackHandle(outcome: .bellFallback)
                }
                return PlaybackHandle(outcome: .unavailable("No native audio player available for \(os.rawValue)"))
            }

            let taskID = state.withLock { s -> UInt64 in
                let id = s.nextTaskID
                s.nextTaskID &+= 1
                return id
            }
            let spawner = self.spawner
            let registration = Mutex<(inserted: Bool, completed: Bool)>((false, false))
            let task = Task<ProcessOutput?, Never> { [weak self] in
                let output = try? await spawner.run(spec)
                let shouldRemove = registration.withLock { r -> Bool in
                    r.completed = true
                    return r.inserted
                }
                if shouldRemove {
                    self?.state.withLock { _ = $0.activeTasks.removeValue(forKey: taskID) }
                }
                return output
            }
            let alreadyCompleted = registration.withLock { r -> Bool in
                r.inserted = true
                return r.completed
            }
            if !alreadyCompleted {
                state.withLock { $0.activeTasks[taskID] = task }
            }

            return PlaybackHandle(
                outcome: .played(executable: spec.executable, arguments: spec.arguments),
                task: task
            )
        }

        /// Plays a bundled `SoundKind` and awaits subprocess completion (never throws).
        @discardableResult
        public func play(
            kind: SoundKind,
            volume: Double? = nil
        ) async -> PlaybackOutcome {
            let handle = playNonBlocking(kind: kind, volume: volume)
            await handle.waitForCompletion()
            return handle.outcome
        }

        /// Plays an audio file path and awaits subprocess completion (never throws).
        @discardableResult
        public func play(
            filePath: String,
            volume: Double? = nil
        ) async -> PlaybackOutcome {
            let handle = playNonBlocking(filePath: filePath, volume: volume)
            await handle.waitForCompletion()
            return handle.outcome
        }

        private func evaluatePreFlightSuppression(volume: Double?) -> PlaybackOutcome? {
            if isMuted || TUIAttentionAudio.isEnvironmentMuted(env) {
                return .suppressed(.muted)
            }
            if let volume, (!volume.isFinite || volume <= 0) {
                return .suppressed(.zeroVolume)
            }
            if !PlatformCapabilities.forOS(os).supportsSubprocesses {
                if let bell = bellFallback, bell() {
                    return .bellFallback
                }
                return .suppressed(.unsupportedPlatform)
            }
            if headlessDetector(env, os) {
                if let bell = bellFallback, bell() {
                    return .bellFallback
                }
                return .suppressed(.headless)
            }
            return nil
        }

        private func validateFileSynchronously(at path: String) -> AudioFileStatus {
            if let customValidator = fileValidator {
                return customValidator(path)
            }
            #if os(WASI)
            return .missing
            #else
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  !isDir.boolValue
            else {
                return .missing
            }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
                return .missing
            }
            return TUIAttentionAudio.isValidAudioData(Array(data), path: path) ? .valid : .invalidData
            #endif
        }
    }
}

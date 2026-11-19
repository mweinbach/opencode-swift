import Synchronization
import Testing
import OpenCodeCore
import OpenCodePlatform
import OpenCodeTUI

@Suite("TUI Attention Audio Assets & Cross-Platform Native Playback")
struct TUIAttentionAudioTests {

    // MARK: - 1. Bundled .mp3 Resources & MPEG/ID3 Validation

    @Test("All 5 bundled attention .mp3 assets exist in Bundle.module with valid ID3v2 and MPEG headers")
    func allFiveBundledMP3AssetsExistAndAreValid() throws {
        let expectedFilenames: [(TUIAttentionAudio.SoundKind, String, Int)] = [
            (.default, "bip-bop-01.mp3", 4574),
            (.question, "bip-bop-03.mp3", 4186),
            (.permission, "staplebops-06.mp3", 4971),
            (.error, "nope-03.mp3", 3820),
            (.subagentDone, "yup-01.mp3", 4418),
        ]

        #expect(TUIAttentionAudio.SoundKind.allCases.count == 5)

        for (kind, filename, expectedBytes) in expectedFilenames {
            #expect(kind.filename == filename)

            let resolvedPath = try #require(TUIAttentionAudio.bundledSoundPath(for: kind))
            #expect(resolvedPath.hasSuffix(filename))
            #expect(!resolvedPath.hasPrefix("@opencode/"))
            #expect(TUIAttentionAudioTestHelper.fileExists(at: resolvedPath))

            let directPath = try #require(TUIAttentionAudioTestHelper.bundledResourcePath(for: kind))
            #expect(directPath == resolvedPath)

            let bytes = try #require(TUIAttentionAudio.bundledSoundBytes(for: kind))
            #expect(bytes.count == expectedBytes)

            let inspection = try #require(TUIAttentionAudio.verifyBundledSound(kind))
            #expect(inspection.isValid)
            #expect(inspection.byteCount == expectedBytes)
            #expect(inspection.hasID3v2Header)
            #expect(inspection.id3MajorVersion == 4)
            #expect(inspection.hasMPEGFrameSync)
            #expect(inspection.mpegFrameOffset != nil)
            #expect(TUIAttentionAudio.isValidMP3Data(bytes))
        }
    }

    @Test("Bundled sound resolver supports flattened bundle layouts as fallback")
    func flattenedBundleLookupFallback() throws {
        try TUIAttentionAudioTestHelper.withFlattenedBundle(containing: .permission) { resolved in
            let path = try #require(resolved)
            #expect(path.hasSuffix("staplebops-06.mp3"))
            #expect(TUIAttentionAudioTestHelper.fileExists(at: path))
            let bytes = try #require(TUIAttentionAudioTestHelper.readFileBytes(at: path))
            #expect(TUIAttentionAudio.isValidMP3Data(bytes))
        }
    }

    @Test("MP3 inspection accepts ID3v2 + MPEG and raw MPEG sync, and rejects invalid payloads")
    func mp3InspectionValidation() {
        // Raw MPEG1 Layer III frame sync (no ID3v2 header)
        let rawMPEG: [UInt8] = [0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00]
        let rawInspection = TUIAttentionAudio.inspectMP3(rawMPEG)
        #expect(rawInspection.isValid)
        #expect(!rawInspection.hasID3v2Header)
        #expect(rawInspection.hasMPEGFrameSync)
        #expect(rawInspection.mpegFrameOffset == 0)

        // Empty, too short, plain text, WAV header, PNG header
        #expect(!TUIAttentionAudio.isValidMP3Data([]))
        #expect(!TUIAttentionAudio.isValidMP3Data([0xFF, 0xFB]))
        #expect(!TUIAttentionAudio.isValidMP3Data(Array("not an mp3 file".utf8)))
        #expect(!TUIAttentionAudio.isValidMP3Data(Array("RIFF....WAVEfmt ".utf8)))
        #expect(!TUIAttentionAudio.isValidMP3Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        // ID3v2 header with zero audio frame payload after tag -> invalid
        let id3Only: [UInt8] = [0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00]
        let id3OnlyInspection = TUIAttentionAudio.inspectMP3(id3Only)
        #expect(id3OnlyInspection.hasID3v2Header)
        #expect(!id3OnlyInspection.hasMPEGFrameSync)
        #expect(!id3OnlyInspection.isValid)

        // Reserved MPEG version bits (01) / reserved layer (00) / invalid bitrate (1111)
        #expect(!TUIAttentionAudio.isValidMP3Data([0xFF, 0xEA, 0x90, 0x00]))
        #expect(!TUIAttentionAudio.isValidMP3Data([0xFF, 0xF1, 0x90, 0x00]))
        #expect(!TUIAttentionAudio.isValidMP3Data([0xFF, 0xFB, 0xF0, 0x00]))
    }

    // MARK: - 2. Sound-Kind & TUIAttention Path Mapping

    @Test("Sound-kind mapping covers all AttentionSoundName cases, BunSounds, and OPENCODE_NODE_ASSETS_DIR override")
    func soundKindAndBunSoundsMapping() {
        #expect(TUIAttentionAudio.SoundKind(soundName: .default) == .default)
        #expect(TUIAttentionAudio.SoundKind(soundName: .done) == .default)
        #expect(TUIAttentionAudio.SoundKind(soundName: .question) == .question)
        #expect(TUIAttentionAudio.SoundKind(soundName: .permission) == .permission)
        #expect(TUIAttentionAudio.SoundKind(soundName: .error) == .error)
        #expect(TUIAttentionAudio.SoundKind(soundName: .subagentDone) == .subagentDone)

        // TUIAttention & BunSounds both resolve real existing bundled .mp3 paths
        #expect(TUIAttention.defaultSoundPath.hasSuffix("bip-bop-01.mp3"))
        #expect(TUIAttention.questionSoundPath.hasSuffix("bip-bop-03.mp3"))
        #expect(TUIAttention.permissionSoundPath.hasSuffix("staplebops-06.mp3"))
        #expect(TUIAttention.errorSoundPath.hasSuffix("nope-03.mp3"))
        #expect(TUIAttention.subagentDoneSoundPath.hasSuffix("yup-01.mp3"))

        #expect(TUIAttention.BunSounds.defaultSoundPath == TUIAttention.defaultSoundPath)
        #expect(TUIAttention.BunSounds.questionSoundPath == TUIAttention.questionSoundPath)
        #expect(TUIAttention.BunSounds.permissionSoundPath == TUIAttention.permissionSoundPath)
        #expect(TUIAttention.BunSounds.errorSoundPath == TUIAttention.errorSoundPath)
        #expect(TUIAttention.BunSounds.subagentDoneSoundPath == TUIAttention.subagentDoneSoundPath)

        for name in PluginTui.AttentionSoundName.allCases {
            let path = TUIAttention.soundPath(for: name)
            #expect(TUIAttentionAudioTestHelper.fileExists(at: path))
            let expectedFilename = TUIAttentionAudio.SoundKind(soundName: name).filename
            #expect(path.hasSuffix(expectedFilename))
        }
        #expect(TUIAttention.soundPath(for: .done) == TUIAttention.defaultSoundPath)

        // Logical alias resolution maps @opencode/ui/audio/* back to real bundled path
        let resolvedFromKey = TUIAttentionAudio.resolveBundledFilePath("@opencode/ui/audio/nope-03.mp3")
        #expect(resolvedFromKey == TUIAttention.errorSoundPath)
        #expect(TUIAttentionAudio.SoundKind.from(filenameOrKey: "yup-01.mp3") == .subagentDone)
        #expect(TUIAttentionAudio.SoundKind.from(filenameOrKey: "@opencode/ui/audio/bip-bop-03.mp3") == .question)
        #expect(TUIAttentionAudio.SoundKind.from(filenameOrKey: "unknown.mp3") == nil)

        // Explicit OPENCODE_NODE_ASSETS_DIR override is honored
        let customEnv = DictionaryEnvironment(variables: ["OPENCODE_NODE_ASSETS_DIR": "/opt/opencode/assets"])
        #expect(
            TUIAttentionAudio.resolveAssetPath(for: .permission, env: customEnv)
                == "/opt/opencode/assets/@opencode/ui/audio/staplebops-06.mp3"
        )
    }

    // MARK: - 3. Cross-Platform Command Construction Per OS

    @Test("macOS command construction targets /usr/bin/afplay with optional volume scaling")
    func macOSCommandConstruction() throws {
        let samplePath = "/tmp/sounds/bip-bop-01.mp3"

        let fullVol = try #require(TUIAttentionAudio.playbackCommand(forPath: samplePath, os: .macOS))
        #expect(fullVol.executable == "/usr/bin/afplay")
        #expect(fullVol.arguments == [samplePath])

        let explicitFull = try #require(TUIAttentionAudio.playbackCommand(forPath: samplePath, os: .macOS, volume: 1.0))
        #expect(explicitFull.executable == "/usr/bin/afplay")
        #expect(explicitFull.arguments == [samplePath])

        let scaled = try #require(TUIAttentionAudio.playbackCommand(forPath: samplePath, os: .macOS, volume: 0.4))
        #expect(scaled.executable == "/usr/bin/afplay")
        #expect(scaled.arguments == ["-v", "0.4", samplePath])

        #expect(TUIAttentionAudio.playbackCommand(forPath: samplePath, os: .macOS, volume: 0.0) == nil)
        #expect(TUIAttentionAudio.playbackCommand(forPath: samplePath, os: .macOS, volume: -0.2) == nil)
        #expect(TUIAttentionAudio.playbackCommand(forPath: samplePath, os: .macOS, volume: .nan) == nil)
        #expect(TUIAttentionAudio.playbackCommand(forPath: samplePath, os: .macOS, executableLookup: { _ in nil }) == nil)
    }

    @Test("Linux command construction selects first available player in priority order with proper flags")
    func linuxCommandPriorityAndFlags() throws {
        let samplePath = "/usr/share/opencode/staplebops-06.mp3"

        // 1. paplay wins when all players exist
        let rawPaplayDefault = TUIAttentionAudio.playbackCommand(
            forPath: samplePath,
            os: .linux,
            executableLookup: { "/usr/bin/\($0)" }
        )
        let paplayDefault = try #require(rawPaplayDefault)
        #expect(paplayDefault.executable == "/usr/bin/paplay")
        #expect(paplayDefault.arguments == [samplePath])

        let rawPaplayScaled = TUIAttentionAudio.playbackCommand(
            forPath: samplePath,
            os: .linux,
            volume: 0.5,
            executableLookup: { $0 == "paplay" ? "/usr/bin/paplay" : nil }
        )
        let paplayScaled = try #require(rawPaplayScaled)
        #expect(paplayScaled.executable == "/usr/bin/paplay")
        #expect(paplayScaled.arguments == ["--volume=32768", samplePath])

        // 2. pw-play when paplay is missing
        let rawPwPlay = TUIAttentionAudio.playbackCommand(
            forPath: samplePath,
            os: .linux,
            volume: 0.75,
            executableLookup: { $0 == "pw-play" || $0 == "ffplay" ? "/usr/bin/\($0)" : nil }
        )
        let pwPlay = try #require(rawPwPlay)
        #expect(pwPlay.executable == "/usr/bin/pw-play")
        #expect(pwPlay.arguments == ["--volume", "0.75", samplePath])

        // 3. ffplay when paplay and pw-play are missing
        let rawFfplayDefault = TUIAttentionAudio.playbackCommand(
            forPath: samplePath,
            os: .linux,
            executableLookup: { $0 == "ffplay" || $0 == "mpg123" ? "/usr/bin/\($0)" : nil }
        )
        let ffplayDefault = try #require(rawFfplayDefault)
        #expect(ffplayDefault.executable == "/usr/bin/ffplay")
        #expect(ffplayDefault.arguments == ["-nodisp", "-autoexit", "-loglevel", "quiet", samplePath])

        let rawFfplayScaled = TUIAttentionAudio.playbackCommand(
            forPath: samplePath,
            os: .linux,
            volume: 0.5,
            executableLookup: { $0 == "ffplay" ? "/usr/bin/ffplay" : nil }
        )
        let ffplayScaled = try #require(rawFfplayScaled)
        #expect(ffplayScaled.arguments == ["-nodisp", "-autoexit", "-loglevel", "quiet", "-volume", "50", samplePath])

        // 4. mpg123 when paplay, pw-play, ffplay are missing
        let rawMpg123Default = TUIAttentionAudio.playbackCommand(
            forPath: samplePath,
            os: .linux,
            executableLookup: { $0 == "mpg123" || $0 == "aplay" ? "/usr/bin/\($0)" : nil }
        )
        let mpg123Default = try #require(rawMpg123Default)
        #expect(mpg123Default.executable == "/usr/bin/mpg123")
        #expect(mpg123Default.arguments == ["-q", samplePath])

        let rawMpg123Scaled = TUIAttentionAudio.playbackCommand(
            forPath: samplePath,
            os: .linux,
            volume: 0.5,
            executableLookup: { $0 == "mpg123" ? "/usr/bin/mpg123" : nil }
        )
        let mpg123Scaled = try #require(rawMpg123Scaled)
        #expect(mpg123Scaled.arguments == ["-q", "-f", "16384", samplePath])

        // 5. aplay as final fallback
        let rawAplay = TUIAttentionAudio.playbackCommand(
            forPath: samplePath,
            os: .linux,
            executableLookup: { $0 == "aplay" ? "/usr/bin/aplay" : nil }
        )
        let aplay = try #require(rawAplay)
        #expect(aplay.executable == "/usr/bin/aplay")
        #expect(aplay.arguments == [samplePath])

        // 6. None available -> nil
        let none = TUIAttentionAudio.playbackCommand(
            forPath: samplePath,
            os: .linux,
            executableLookup: { _ in nil }
        )
        #expect(none == nil)
    }

    @Test("Windows command construction uses PowerShell MediaPlayer with SoundPlayer fallback and escapes quotes")
    func windowsCommandConstruction() throws {
        let winPath = #"C:\Users\O'Brien\OpenCode\bip-bop-01.mp3"#

        let rawCmd = TUIAttentionAudio.playbackCommand(
            forPath: winPath,
            os: .windows,
            volume: 0.6,
            executableLookup: { $0 == "powershell.exe" ? #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"# : nil }
        )
        let cmd = try #require(rawCmd)
        #expect(cmd.executable == #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#)
        #expect(cmd.arguments.prefix(5) == ["-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command"])

        let script = try #require(cmd.arguments.last)
        #expect(script.contains("PresentationCore"))
        #expect(script.contains("System.Windows.Media.MediaPlayer"))
        #expect(script.contains("$m.Volume = 0.6"))
        #expect(script.contains("System.Media.SoundPlayer"))
        // Single quote inside Windows path is doubled for safe PowerShell single-quoted literal
        #expect(script.contains(#"$p = 'C:\Users\O''Brien\OpenCode\bip-bop-01.mp3'"#))
    }

    @Test("WASI, iOS, and unsafe paths produce nil playback command and deterministic gain formatting")
    func unsupportedPlatformsAndUnsafePaths() {
        let path = "/tmp/bip-bop-01.mp3"
        #expect(TUIAttentionAudio.playbackCommand(forPath: path, os: .wasi) == nil)
        #expect(TUIAttentionAudio.playbackCommand(forPath: path, os: .iOS) == nil)
        #expect(TUIAttentionAudio.playbackCommand(forPath: path, os: .tvOS) == nil)
        #expect(TUIAttentionAudio.playbackCommand(forPath: path, os: .watchOS) == nil)
        #expect(TUIAttentionAudio.playbackCommand(forPath: path, os: .visionOS) == nil)

        #expect(TUIAttentionAudio.playbackCommand(forPath: "", os: .macOS) == nil)
        #expect(TUIAttentionAudio.playbackCommand(forPath: "/tmp/bad\u{0}.mp3", os: .macOS) == nil)
        #expect(TUIAttentionAudio.playbackCommand(forPath: "/tmp/bad\n.mp3", os: .macOS) == nil)

        #expect(TUIAttentionAudio.formatGain(0.0) == "0")
        #expect(TUIAttentionAudio.formatGain(0.05) == "0.05")
        #expect(TUIAttentionAudio.formatGain(0.4) == "0.4")
        #expect(TUIAttentionAudio.formatGain(0.75) == "0.75")
        #expect(TUIAttentionAudio.formatGain(1.0) == "1")
        #expect(TUIAttentionAudio.formatGain(1.5) == "1")
        #expect(TUIAttentionAudio.formatGain(-1.0) == "0")
        #expect(TUIAttentionAudio.formatGain(.nan) == "0")
    }

    // MARK: - 4. Mute, Headless, WASI/iOS & Error Resilience

    @Test("Muted player, zero volume, headless, WASI, iOS, and missing player handle suppression and bell fallback gracefully")
    func muteHeadlessPlatformAndBellFallbacks() async throws {
        let spawner = TUIAttentionAudioTestHelper.MockProcessSpawner()
        let bells = Mutex<[String]>([])
        let bellHandler = TUIAttentionAudio.makeBellFallback { chunk in
            bells.withLock { $0.append(chunk) }
        }

        // 1. Muted player never spawns subprocess and never rings bell
        let mutedPlayer = TUIAttentionAudio.Player(
            os: .macOS,
            spawner: spawner,
            env: DictionaryEnvironment(),
            executableLookup: { $0 },
            muted: true,
            bellFallback: bellHandler
        )
        #expect(mutedPlayer.playNonBlocking(kind: .default, volume: 0.8).outcome == .suppressed(.muted))
        #expect(spawner.specs.isEmpty)
        #expect(bells.withLock { $0 }.isEmpty)

        // 2. Environment mute flag (OPENCODE_AUDIO_MUTED=1) suppresses playback and bell
        let envMutedPlayer = TUIAttentionAudio.Player(
            os: .macOS,
            spawner: spawner,
            env: DictionaryEnvironment(variables: ["OPENCODE_AUDIO_MUTED": "1"]),
            executableLookup: { $0 },
            bellFallback: bellHandler
        )
        #expect(envMutedPlayer.playNonBlocking(kind: .error, volume: 0.5).outcome == .suppressed(.muted))
        #expect(spawner.specs.isEmpty)
        #expect(bells.withLock { $0 }.isEmpty)

        // 3. Zero or NaN volume suppresses playback and bell
        let activePlayer = TUIAttentionAudio.Player(
            os: .macOS,
            spawner: spawner,
            env: DictionaryEnvironment(),
            executableLookup: { $0 },
            bellFallback: bellHandler
        )
        #expect(activePlayer.playNonBlocking(kind: .question, volume: 0.0).outcome == .suppressed(.zeroVolume))
        #expect(activePlayer.playNonBlocking(kind: .question, volume: .nan).outcome == .suppressed(.zeroVolume))
        #expect(spawner.specs.isEmpty)
        #expect(bells.withLock { $0 }.isEmpty)

        // 4. Headless without bell -> silent no-op; with bell -> BEL fallback
        let headlessSilent = TUIAttentionAudio.Player(
            os: .macOS,
            spawner: spawner,
            env: DictionaryEnvironment(variables: ["OPENCODE_HEADLESS": "1"]),
            executableLookup: { $0 }
        )
        #expect(headlessSilent.playNonBlocking(kind: .default).outcome == .suppressed(.headless))

        let headlessBell = TUIAttentionAudio.Player(
            os: .linux,
            spawner: spawner,
            env: DictionaryEnvironment(variables: ["SSH_TTY": "/dev/pts/0"]),
            executableLookup: { _ in "/usr/bin/paplay" },
            bellFallback: bellHandler
        )
        #expect(headlessBell.playNonBlocking(kind: .default).outcome == .bellFallback)

        // 5. WASI and iOS without bell -> unsupportedPlatform; with bell -> BEL fallback
        let wasiSilent = TUIAttentionAudio.Player(os: .wasi, spawner: spawner, env: DictionaryEnvironment())
        #expect(wasiSilent.playNonBlocking(kind: .default).outcome == .suppressed(.unsupportedPlatform))

        let iosBell = TUIAttentionAudio.Player(
            os: .iOS,
            spawner: spawner,
            env: DictionaryEnvironment(),
            bellFallback: bellHandler
        )
        #expect(iosBell.playNonBlocking(kind: .permission).outcome == .bellFallback)

        // 6. Linux with no installed player -> unavailable (or bell fallback when configured)
        let linuxNoPlayer = TUIAttentionAudio.Player(
            os: .linux,
            spawner: spawner,
            env: DictionaryEnvironment(),
            executableLookup: { _ in nil }
        )
        if case .unavailable = linuxNoPlayer.playNonBlocking(kind: .default).outcome {
            // expected
        } else {
            Issue.record("Expected .unavailable when no Linux player binary is present")
        }

        // 7. Corrupt MP3 file on disk -> suppressed(.invalidAudioData) without spawning
        try await TUIAttentionAudioTestHelper.withTemporaryFile(
            named: "corrupt.mp3",
            bytes: Array("definitely not valid mp3 bytes".utf8)
        ) { corruptPath in
            let outcome = activePlayer.playNonBlocking(filePath: corruptPath, volume: 0.5).outcome
            #expect(outcome == .suppressed(.invalidAudioData))
        }

        // 8. Throwing spawner is caught non-throwingly
        let failingSpawner = TUIAttentionAudioTestHelper.MockProcessSpawner(shouldThrow: true)
        let resilientPlayer = TUIAttentionAudio.Player(
            os: .macOS,
            spawner: failingSpawner,
            env: DictionaryEnvironment(),
            executableLookup: { $0 }
        )
        let outcome = await resilientPlayer.play(kind: .error, volume: 0.5)
        if case .played(let exec, _) = outcome {
            #expect(exec == "/usr/bin/afplay")
        } else {
            Issue.record("Expected .played dispatch even when subprocess fails asynchronously")
        }
        #expect(failingSpawner.completedCount == 1)

        // Total subprocess calls on primary spawner must remain 0; two bells fired (headlessBell + iosBell)
        #expect(spawner.specs.isEmpty)
        #expect(bells.withLock { $0 } == ["\u{07}", "\u{07}"])
    }

    // MARK: - 5. Non-Blocking Playback via Gated Mock ProcessSpawner

    @Test("TUIAttention.playSound dispatches non-blockingly via mock ProcessSpawner and supports cancellation")
    func nonBlockingPlaybackAndCancellation() async throws {
        let gatedSpawner = TUIAttentionAudioTestHelper.MockProcessSpawner(blockExecution: true)
        let player = TUIAttentionAudio.Player(
            os: .macOS,
            spawner: gatedSpawner,
            env: DictionaryEnvironment(),
            executableLookup: { $0 }
        )

        // Dispatch synchronously — must return immediately even while spawner is blocked!
        let handle = TUIAttention.playSound(.permission, volume: 0.5, player: player)
        let expectedPath = TUIAttention.permissionSoundPath
        #expect(handle.outcome == .played(executable: "/usr/bin/afplay", arguments: ["-v", "0.5", expectedPath]))

        // Wait until background Task enters mock spawner, then verify it has NOT completed yet.
        await gatedSpawner.waitUntilStarted(count: 1)
        #expect(gatedSpawner.startedCount == 1)
        #expect(gatedSpawner.completedCount == 0)
        #expect(gatedSpawner.specs == [ProcessSpec(executable: "/usr/bin/afplay", arguments: ["-v", "0.5", expectedPath])])

        // Release gate and await completion cleanly.
        gatedSpawner.release()
        let output = await handle.waitForCompletion()
        #expect(output?.exitCode == 0)
        #expect(gatedSpawner.completedCount == 1)
        #expect(player.activePlaybackCount == 0)

        // Verify cancellation of an in-flight blocked playback task
        let cancelSpawner = TUIAttentionAudioTestHelper.MockProcessSpawner(blockExecution: true)
        let cancelPlayer = TUIAttentionAudio.Player(
            os: .linux,
            spawner: cancelSpawner,
            env: DictionaryEnvironment(),
            executableLookup: { $0 == "ffplay" ? "/usr/bin/ffplay" : nil }
        )
        let handle2 = TUIAttention.playSound(.subagentDone, volume: 1.0, player: cancelPlayer)
        #expect(handle2.outcome == .played(
            executable: "/usr/bin/ffplay",
            arguments: ["-nodisp", "-autoexit", "-loglevel", "quiet", TUIAttention.subagentDoneSoundPath]
        ))
        await cancelSpawner.waitUntilStarted(count: 1)
        cancelPlayer.cancelAll()
        _ = await handle2.waitForCompletion()
        #expect(cancelSpawner.cancelledCount == 1)
        #expect(cancelPlayer.activePlaybackCount == 0)
    }

    @Test("TUIAttention.playSound falls back from missing override to real bundled .mp3 asset")
    func playSoundOverrideFallbackToBundledAsset() async {
        let spawner = TUIAttentionAudioTestHelper.MockProcessSpawner()
        let player = TUIAttentionAudio.Player(
            os: .macOS,
            spawner: spawner,
            env: DictionaryEnvironment(),
            executableLookup: { $0 }
        )

        let handle = TUIAttention.playSound(
            .error,
            volume: 0.75,
            overrides: [.error: "/nonexistent/path/custom-error.mp3"],
            player: player
        )
        #expect(handle.outcome == .played(
            executable: "/usr/bin/afplay",
            arguments: ["-v", "0.75", TUIAttention.errorSoundPath]
        ))
        await handle.waitForCompletion()
        #expect(spawner.specs.count == 1)
        #expect(spawner.specs[0].arguments == ["-v", "0.75", TUIAttention.errorSoundPath])
    }

    // MARK: - 6. Focus Suppression & End-to-End createTuiAttention Wiring

    @Test("TUIAttention.createTuiAttention enforces focus suppression, mute, sound-kind routing, and non-blocking playback")
    func createTuiAttentionFocusMuteAndSoundRouting() async {
        let renderer = TUIAttentionAudioTestHelper.MockAttentionRenderer()
        let spawner = TUIAttentionAudioTestHelper.MockProcessSpawner(blockExecution: true)
        let player = TUIAttentionAudio.Player(
            os: .macOS,
            spawner: spawner,
            env: DictionaryEnvironment(),
            executableLookup: { $0 }
        )

        let config = TUIConfig.ResolvedAttention(
            notifications: false,
            sound: true,
            volume: 0.4,
            sounds: [.question: "/nonexistent/override/question.mp3"]
        )
        let host = TUIAttention.createTuiAttention(renderer: renderer, config: config, player: player)
        defer { host.dispose() }

        // 1. Focus unknown + sound when=.blurred -> skipped, no subprocess launched
        let rUnknown = await host.notify(PluginTui.AttentionNotifyOptions(
            message: "Needs approval",
            sound: .configured(name: .permission, volume: 0.6, when: .blurred)
        ))
        #expect(!rUnknown.ok)
        #expect(!rUnknown.sound)
        #expect(rUnknown.skipped == .focusUnknown)
        #expect(spawner.specs.isEmpty)

        // 2. Focused + sound when=.blurred -> skipped(.focused), no subprocess launched
        renderer.emitFocus()
        let rFocused = await host.notify(PluginTui.AttentionNotifyOptions(
            message: "Needs approval",
            sound: .configured(name: .permission, volume: 0.6, when: .blurred)
        ))
        #expect(!rFocused.ok)
        #expect(!rFocused.sound)
        #expect(rFocused.skipped == .focused)
        #expect(spawner.specs.isEmpty)

        // 3. Explicit sound=.enabled(false) -> suppressed
        let rDisabled = await host.notify(PluginTui.AttentionNotifyOptions(
            message: "Silent message",
            sound: .enabled(false)
        ))
        #expect(!rDisabled.ok)
        #expect(!rDisabled.sound)
        #expect(spawner.specs.isEmpty)

        // 4. Blurred + sound when=.blurred -> plays real bundled staplebops-06.mp3 non-blockingly!
        renderer.emitBlur()
        let rBlurred = await host.notify(PluginTui.AttentionNotifyOptions(
            message: "Approve shell command",
            sound: .configured(name: .permission, volume: 0.6, when: .blurred)
        ))
        #expect(rBlurred.ok)
        #expect(rBlurred.sound)
        #expect(rBlurred.skipped == nil)

        // notify() returned immediately while spawner is still blocked!
        await spawner.waitUntilStarted(count: 1)
        #expect(spawner.completedCount == 0)
        #expect(spawner.specs.last == ProcessSpec(
            executable: "/usr/bin/afplay",
            arguments: ["-v", "0.6", TUIAttention.permissionSoundPath]
        ))

        // Release gate for remaining assertions
        spawner.release()
        await player.waitForAll()
        #expect(spawner.completedCount == 1)

        // 5. Question sound with missing override falls back cleanly to real bundled bip-bop-03.mp3
        let rQuestion = await host.notify(PluginTui.AttentionNotifyOptions(
            message: "Clarification needed",
            sound: .configured(name: .question, volume: nil, when: .always)
        ))
        #expect(rQuestion.ok)
        #expect(rQuestion.sound)
        await player.waitForAll()
        #expect(spawner.specs.last == ProcessSpec(
            executable: "/usr/bin/afplay",
            arguments: ["-v", "0.4", TUIAttention.questionSoundPath]
        ))

        // 6. Done aliases default (bip-bop-01.mp3), subagentDone uses yup-01.mp3
        let rDone = await host.notify(PluginTui.AttentionNotifyOptions(
            message: "Task finished",
            sound: .configured(name: .done, volume: 1.0, when: .always)
        ))
        #expect(rDone.sound)
        let rSubagent = await host.notify(PluginTui.AttentionNotifyOptions(
            message: "Subagent finished",
            sound: .configured(name: .subagentDone, volume: 0.8, when: .always)
        ))
        #expect(rSubagent.sound)
        await player.waitForAll()

        #expect(spawner.specs.contains(ProcessSpec(
            executable: "/usr/bin/afplay",
            arguments: [TUIAttention.defaultSoundPath]
        )))
        #expect(spawner.specs.contains(ProcessSpec(
            executable: "/usr/bin/afplay",
            arguments: ["-v", "0.8", TUIAttention.subagentDoneSoundPath]
        )))

        // 7. Muting the player suppresses subsequent sounds cleanly
        let countBeforeMute = spawner.specs.count
        player.isMuted = true
        let rMuted = await host.notify(PluginTui.AttentionNotifyOptions(
            message: "Muted alert",
            sound: .configured(name: .error, volume: 0.9, when: .always)
        ))
        #expect(!rMuted.ok)
        #expect(!rMuted.sound)
        #expect(spawner.specs.count == countBeforeMute)
    }

    @Test("TUIAttention.loadSoundFile caches validated bundled MP3s and createTuiAttention supports WASI bell fallback and custom audio overrides")
    func loadSoundFileAndPlatformFallbackThroughCreateTuiAttention() async throws {
        // loadSoundFile resolves both direct bundled path and @opencode/ui/audio/* alias and rejects missing files
        let loadedDirect = await TUIAttention.loadSoundFile(TUIAttention.defaultSoundPath)
        let loadedDirectAgain = await TUIAttention.loadSoundFile(TUIAttention.defaultSoundPath)
        let directHandle = try #require(loadedDirect)
        #expect(loadedDirectAgain == directHandle)

        let loadedAlias = await TUIAttention.loadSoundFile("@opencode/ui/audio/nope-03.mp3")
        #expect(loadedAlias != nil)
        #expect(await TUIAttention.loadSoundFile("/nonexistent/sound.mp3") == nil)

        // WASI createTuiAttention without bellFallback -> graceful silent no-op (non-throwing)
        let rendererSilent = TUIAttentionAudioTestHelper.MockAttentionRenderer()
        let wasiSilentPlayer = TUIAttentionAudio.Player(
            os: .wasi,
            spawner: TUIAttentionAudioTestHelper.MockProcessSpawner(),
            env: DictionaryEnvironment()
        )
        let silentHost = TUIAttention.createTuiAttention(
            renderer: rendererSilent,
            config: TUIConfig.ResolvedAttention(notifications: false, sound: true, volume: 0.5),
            player: wasiSilentPlayer
        )
        defer { silentHost.dispose() }
        let rSilent = await silentHost.notify(PluginTui.AttentionNotifyOptions(message: "WASI silent"))
        #expect(!rSilent.ok)
        #expect(!rSilent.sound)

        // WASI createTuiAttention with bellFallback -> triggers BEL cleanly
        let bells = Mutex<[String]>([])
        let wasiBellPlayer = TUIAttentionAudio.Player(
            os: .wasi,
            spawner: TUIAttentionAudioTestHelper.MockProcessSpawner(),
            env: DictionaryEnvironment(),
            bellFallback: TUIAttentionAudio.makeBellFallback { chunk in
                bells.withLock { $0.append(chunk) }
            }
        )
        let bellHost = TUIAttention.createTuiAttention(
            renderer: TUIAttentionAudioTestHelper.MockAttentionRenderer(),
            config: TUIConfig.ResolvedAttention(notifications: false, sound: true, volume: 0.5),
            player: wasiBellPlayer
        )
        defer { bellHost.dispose() }
        let rBell = await bellHost.notify(PluginTui.AttentionNotifyOptions(message: "WASI bell"))
        #expect(rBell.ok)
        #expect(rBell.sound)
        #expect(bells.withLock { $0 } == ["\u{07}"])

        // Custom .wav override on disk plays via AudioBackend.native
        try await TUIAttentionAudioTestHelper.withTemporaryFile(
            named: "custom-chime.wav",
            bytes: Array("RIFF\u{24}\u{00}\u{00}\u{00}WAVEfmt ".utf8)
        ) { wavPath in
            let spawner = TUIAttentionAudioTestHelper.MockProcessSpawner()
            let player = TUIAttentionAudio.Player(
                os: .macOS,
                spawner: spawner,
                env: DictionaryEnvironment(),
                executableLookup: { $0 }
            )
            let wavHost = TUIAttention.createTuiAttention(
                renderer: TUIAttentionAudioTestHelper.MockAttentionRenderer(),
                config: TUIConfig.ResolvedAttention(
                    notifications: false,
                    sound: true,
                    volume: 1.0,
                    sounds: [.default: wavPath]
                ),
                player: player
            )
            defer { wavHost.dispose() }
            let result = await wavHost.notify(PluginTui.AttentionNotifyOptions(message: "Custom WAV"))
            #expect(result.ok)
            #expect(result.sound)
            await player.waitForAll()
            #expect(spawner.specs == [ProcessSpec(executable: "/usr/bin/afplay", arguments: [wavPath])])
        }
    }
}

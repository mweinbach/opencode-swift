import OpenTUICore
import Testing

// MARK: - Audio Engine, PCM, WAV, Synth, FFT & Mixer Tests

@Suite("AudioEngineTests")
struct AudioEngineTests {
    @Test("PCM float32 <-> int16 and f32le byte conversions round-trip accurately")
    func pcmConversions() {
        let input: [Float] = [-1.0, -0.5, 0.0, 0.25, 0.5, 1.0]
        let i16 = PCMConverter.float32ToInt16(input)
        #expect(i16[0] == -32767)
        #expect(i16[2] == 0)
        #expect(i16[5] == 32767)

        let back = PCMConverter.int16ToFloat32(i16)
        #expect(back.count == input.count)
        for (a, b) in zip(input, back) {
            #expect(abs(a - b) < 1e-4)
        }

        let i16Bytes = PCMConverter.float32ToInt16BytesLE(input)
        #expect(i16Bytes.count == input.count * 2)
        let fromI16Bytes = PCMConverter.int16BytesLEToFloat32(i16Bytes)
        for (a, b) in zip(input, fromI16Bytes) {
            #expect(abs(a - b) < 1e-4)
        }

        let f32Bytes = PCMConverter.float32ToBytesLE(input)
        #expect(f32Bytes.count == input.count * 4)
        let fromF32Bytes = PCMConverter.bytesLEToFloat32(f32Bytes)
        #expect(fromF32Bytes == input)
    }

    @Test("WAV 16-bit and 32-bit float encode/decode round-trip")
    func wavRoundTrip() throws {
        let sine = AudioSynthesizer.generate(
            waveform: .sine,
            frequency: 440.0,
            duration: 0.05,
            sampleRate: 16_000,
            channels: 2,
            amplitude: 0.75
        )
        #expect(sine.frameCount == 800)
        #expect(sine.channels == 2)

        let wav16 = try WAVCodec.encode(sine, bitsPerSample: 16, asFloat: false)
        #expect(wav16.count == 44 + sine.samples.count * 2)
        #expect(Array(wav16[0..<4]) == Array("RIFF".utf8))
        #expect(Array(wav16[8..<12]) == Array("WAVE".utf8))

        let decoded16 = try WAVCodec.decode(wav16)
        #expect(decoded16.sampleRate == 16_000)
        #expect(decoded16.channels == 2)
        #expect(decoded16.frameCount == 800)
        for i in stride(from: 0, to: sine.samples.count, by: 37) {
            #expect(abs(decoded16.samples[i] - sine.samples[i]) < 1e-3)
        }

        let wavFloat = try WAVCodec.encode(sine, asFloat: true)
        let decodedFloat = try WAVCodec.decode(wavFloat)
        #expect(decodedFloat.samples == sine.samples)
    }

    @Test("Procedural waveforms, ADSR envelope, FFT dominant frequency, and RMS/peak metering")
    func synthFftAndMetering() {
        let sampleRate = 16_384
        let sine = AudioSynthesizer.generate(
            waveform: .sine,
            frequency: 512.0,
            duration: 0.25,
            sampleRate: sampleRate,
            channels: 1,
            amplitude: 0.8
        )
        let reading = AudioLevelMeter.measure(sine.samples)
        #expect(abs(reading.peak - 0.8) < 0.01)
        // RMS of sine wave = amplitude / sqrt(2) ~= 0.5657
        #expect(abs(reading.rms - Float(0.8 / 2.0.squareRoot())) < 0.02)
        #expect(!reading.clipping)
        #expect(reading.rmsDb < 0 && reading.rmsDb > -10)

        let dominant = AudioFFT.dominantFrequency(samples: sine.samples, sampleRate: sampleRate, windowSize: 1024)
        #expect(abs(dominant - 512.0) <= 16.0)

        // Check all waveform types generate bounded non-empty output
        for wave in WaveformType.allCases {
            let buf = AudioSynthesizer.generate(waveform: wave, frequency: 220, duration: 0.02, sampleRate: 8000, channels: 1, amplitude: 0.5)
            #expect(buf.frameCount == 160)
            #expect(buf.peakLevel() > 0.0)
            #expect(buf.peakLevel() <= 0.55)
        }

        let enveloped = AudioSynthesizer.applyEnvelope(sine, attack: 0.05, decay: 0.05, sustain: 0.5, release: 0.05)
        #expect(abs(enveloped.samples[0]) < 0.01)
        #expect(abs(enveloped.samples[enveloped.samples.count - 1]) < 0.05)
    }

    @Test("Multi-voice mixing with gain, group volume, stereo pan, loop, seek, pause, fade, and MemoryAudioOutputSink")
    func multiVoiceMixerAndSink() throws {
        let sink = MemoryAudioOutputSink()
        let audio = try setupAudio(AudioSetupOptions(autoStart: true, sampleRate: 1000, playbackChannels: 2, outputSink: sink))
        defer { audio.dispose() }

        #expect(audio.isStarted())
        #expect(audio.isMixerStarted())

        // Constant DC buffers make gain/pan/fade/seek/loop arithmetic exact and deterministic
        let dcA = AudioPCMBuffer(sampleRate: 1000, channels: 1, samples: Array(repeating: 0.5, count: 100))
        let dcB = AudioPCMBuffer(sampleRate: 1000, channels: 1, samples: Array(repeating: 0.4, count: 100))
        let wavA = try WAVCodec.encode(dcA, asFloat: true)

        let soundA = try #require(audio.loadSound(wavA))
        let soundB = try #require(audio.loadPCMBuffer(dcB))

        let sfxGroup = try #require(audio.group("sfx"))
        #expect(audio.setGroupVolume(sfxGroup, volume: 0.5))
        #expect(audio.setMasterVolume(1.0))

        // Hard-left voice A (volume 1.0, pan -1.0 -> L ~= 0.5 * sqrt(2) ~= 0.707, R ~= 0)
        let voiceA = try #require(audio.play(soundA, options: AudioPlayOptions(volume: 1.0, pan: -1.0, loop: true)))
        // Hard-right voice B in sfxGroup (volume 1.0 * group 0.5 = 0.5, pan +1.0 -> L ~= 0, R ~= 0.4 * 0.5 * sqrt(2) ~= 0.283)
        let voiceB = try #require(audio.play(soundB, options: AudioPlayOptions(volume: 1.0, pan: 1.0, loop: false, groupId: sfxGroup)))

        #expect(audio.enableTap(capacityFrames: 512))

        let mixed = try #require(audio.mixFrames(50, channels: 2))
        #expect(mixed.count == 100)
        #expect(sink.totalFramesWritten == 50)
        #expect(sink.writeCallCount == 1)

        // Check left vs right channel separation
        let sampleL = mixed[10]
        let sampleR = mixed[11]
        #expect(abs(sampleL - Float(0.5 * 2.0.squareRoot())) < 0.02)
        #expect(abs(sampleR - Float(0.2 * 2.0.squareRoot())) < 0.02)

        // Tap captured the same 50 frames
        let tap = try #require(audio.readTapFrames(50, channels: 2))
        #expect(tap.framesRead == 50)
        #expect(tap.frames.count == 100)

        // Pause voiceB and verify only voiceA contributes
        #expect(audio.pauseVoice(voiceB))
        #expect(audio.isVoicePaused(voiceB))
        let pausedMix = try #require(audio.mixFrames(20, channels: 2))
        #expect(abs(pausedMix[1]) < 1e-4) // right channel silent

        // Resume, seek, and fade out voiceA
        #expect(audio.resumeVoice(voiceB))
        #expect(audio.seekVoice(voiceA, toFrame: 95))
        #expect(audio.voicePositionFrames(voiceA) == 95)

        // Mixing 20 frames on looping voiceA wraps seamlessly past 100 frames
        _ = audio.mixFrames(20, channels: 2)
        let posAfterWrap = try #require(audio.voicePositionFrames(voiceA))
        #expect(posAfterWrap >= 14.0 && posAfterWrap <= 16.0)

        // Fade voiceA to silence and auto-stop
        #expect(audio.fadeVoice(voiceA, to: 0.0, durationSeconds: 0.02, stopWhenComplete: true))
        _ = audio.mixFrames(30, channels: 2)
        #expect(!audio.isVoicePlaying(voiceA))

        let stats = try #require(audio.getStats())
        #expect(stats.soundsLoaded == 2)
        #expect(stats.framesMixed == 120)
        #expect(audio.disableTap())
    }

    @Test("Capture stream, WAV recorder, and PCM AudioStream playback")
    func captureRecorderAndStream() async throws {
        let audio = try Audio.create(AudioSetupOptions(sampleRate: 8000, playbackChannels: 1))
        defer { audio.dispose() }

        let recorder = try audio.recordToFile("recording.wav", options: AudioRecordToFileOptions(channels: 1, capacityFrames: 4000, chunkFrames: 256))
        #expect(recorder.state == .recording)

        let tone = AudioSynthesizer.generate(waveform: .sine, frequency: 440, duration: 0.05, sampleRate: 8000, channels: 1, amplitude: 0.6)
        let pushed = audio.pushCaptureFrames(tone.samples)
        #expect(pushed == tone.frameCount)

        recorder.stop()
        #expect(recorder.state == .stopped)

        let wavBytes = try #require(recorder.recordedWavData)
        let decoded = try WAVCodec.decode(wavBytes)
        #expect(decoded.sampleRate == 8000)
        #expect(decoded.channels == 1)
        #expect(decoded.frameCount == tone.frameCount)

        // Test AudioStream PCM ingestion
        let pcmBytes = PCMConverter.float32ToBytesLE(tone.samples)
        let stream = try await audio.playStream(
            .chunks([Array(pcmBytes[0..<100]), Array(pcmBytes[100...])]),
            options: AudioStreamBodyOptions<AudioStreamMetadata>(
                stream: AudioStreamOptions(format: .pcm, sampleFormat: .float32, sampleRate: 8000, channels: 1)
            )
        )
        let streamStats = stream.getStats()
        #expect(streamStats.state == .ended)
        #expect(streamStats.bytesReceived == UInt64(pcmBytes.count))
        #expect(streamStats.framesDecoded == UInt64(tone.frameCount))
        #expect(stream.setVolume(0.7))
        #expect(stream.setPan(-0.25))
        #expect(stream.setGroup(0))
        stream.dispose()
        #expect(stream.state == .disposed)

        // Test playStreamUrl with ICY metadata headers via pure-Swift mock fetcher
        let icyMeta = Array("StreamTitle='Live Jazz';".utf8)
        let padded = icyMeta + Array(repeating: UInt8(0), count: 32 - icyMeta.count)
        let wire: [UInt8] = [1, 2, 3, 4, 2] + padded + [5, 6]
        let urlStream = try await audio.playStreamUrl(
            "https://stream.example/jazz.mp3",
            options: AudioStreamUrlOptions(
                stream: AudioStreamOptions(format: .mp3),
                fetcher: { _, reqHeaders in
                    #expect(reqHeaders["Icy-MetaData"] == "1")
                    return AudioStreamUrlResponse(
                        status: 200,
                        headers: ["Content-Type": "audio/mpeg", "icy-metaint": "4", "icy-name": "Jazz FM"],
                        body: .chunks([wire]),
                        url: "https://stream.example/jazz.mp3"
                    )
                }
            )
        )
        #expect(urlStream.getMetadata()?.streamTitle == "Live Jazz")
        #expect(urlStream.getMetadata()?.headers["icy-name"] == "Jazz FM")
        #expect(urlStream.getStats().bytesReceived == 6)
        urlStream.dispose()

        // Test device enumeration & selection
        #expect(audio.listPlaybackDevices()?.count == 1)
        #expect(audio.selectPlaybackDevice(0))
        audio.clearPlaybackDeviceSelection()
        #expect(audio.listCaptureDevices()?.count == 1)
        #expect(audio.selectCaptureDevice(0))
        audio.clearCaptureDeviceSelection()
    }
}

// MARK: - ICY Stream Demuxer & Metadata Tests

@Suite("IcyDemuxerTests")
struct IcyDemuxerTests {
    private func buildIcyMetadataBlock(_ text: String) -> [UInt8] {
        let utf8 = Array(text.utf8)
        let paddedLen = ((utf8.count + 15) / 16) * 16
        let lengthByte = UInt8(paddedLen / 16)
        var block: [UInt8] = [lengthByte]
        block.append(contentsOf: utf8)
        if paddedLen > utf8.count {
            block.append(contentsOf: Array(repeating: 0, count: paddedLen - utf8.count))
        }
        return block
    }

    @Test("parseIcyMetadata extracts StreamTitle, StreamUrl, custom pairs, and respects NUL padding")
    func parseIcyMetadataFields() {
        var bytes = Array("StreamTitle='Synthwave - Night Drive';StreamUrl='https://radio.example/live';Genre='Electronic';".utf8)
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(contentsOf: Array("Ignored='AfterNul';".utf8))

        let fields = parseIcyMetadata(bytes)
        #expect(fields?["StreamTitle"] == "Synthwave - Night Drive")
        #expect(fields?["StreamUrl"] == "https://radio.example/live")
        #expect(fields?["Genre"] == "Electronic")
        #expect(fields?["Ignored"] == nil)

        #expect(parseIcyMetadata([0, 0, 0, 0]) == nil)
        #expect(parseIcyMetadata(Array("MalformedWithoutTerminator='abc".utf8)) == nil)
    }

    @Test("IcyStreamDemuxer separates audio and metadata cleanly across single-byte fragmented chunks")
    func icyDemuxerFragmentedChunks() throws {
        let interval = 8
        let demuxer = try createIcyStreamDemuxer(
            IcyStreamDemuxerOptions(
                metadataInterval: interval,
                metadataEncoding: "utf-8",
                headers: ["Icy-Name": "OpenTUI Radio", "Icy-MetaInt": "\(interval)"]
            )
        )
        #expect(demuxer.initialMetadata?.headers["icy-name"] == "OpenTUI Radio")

        let audio1: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
        let meta1 = buildIcyMetadataBlock("StreamTitle='Track One';StreamUrl='https://a.test';")
        let audio2: [UInt8] = [11, 12, 13, 14, 15, 16, 17, 18]
        let metaEmpty: [UInt8] = [0] // zero-length metadata block
        let audio3: [UInt8] = [21, 22, 23, 24, 25, 26, 27, 28]
        let metaSame = buildIcyMetadataBlock("StreamTitle='Track One';StreamUrl='https://a.test';")
        let audio4: [UInt8] = [31, 32, 33, 34, 35, 36, 37, 38]
        let meta2 = buildIcyMetadataBlock("StreamTitle='Track Two';")
        let audioTail: [UInt8] = [41, 42, 43]

        let wire = audio1 + meta1 + audio2 + metaEmpty + audio3 + metaSame + audio4 + meta2 + audioTail

        var collectedAudio: [UInt8] = []
        var collectedTitles: [String] = []

        // Feed one byte at a time to stress-test framing across arbitrary boundaries
        for byte in wire {
            for item in demuxer.push([byte]) {
                switch item {
                case .audio(let bytes):
                    collectedAudio.append(contentsOf: bytes)
                case .metadata(let meta):
                    if let title = meta?.streamTitle {
                        collectedTitles.append(title)
                    }
                }
            }
        }
        let flushed = try demuxer.flush()
        #expect(flushed.isEmpty)

        #expect(collectedAudio == audio1 + audio2 + audio3 + audio4 + audioTail)
        // Repeated identical metadata block is deduplicated; only transitions emit
        #expect(collectedTitles == ["Track One", "Track Two"])
    }

    @Test("selectAudioStreamDemuxer validates icy-metaint and flush detects truncated metadata")
    func selectDemuxerAndTruncatedFlush() throws {
        let none = try selectAudioStreamDemuxer(headers: ["Content-Type": "audio/mpeg"])
        #expect(none == nil)

        let selected = try #require(
            try selectAudioStreamDemuxer(headers: ["Content-Type": "audio/mpeg", "ICY-MetaInt": "4", "Icy-Br": "128"])
        )
        #expect(selected.initialMetadata?.headers["icy-br"] == "128")

        // Push exactly 4 audio bytes + length byte 1 (16 bytes expected) + only 3 metadata bytes -> flush throws
        _ = selected.push([1, 2, 3, 4, 1, 65, 66, 67])
        #expect(throws: AudioStreamDemuxerError.truncatedMetadataBlock) {
            _ = try selected.flush()
        }

        #expect(throws: AudioStreamDemuxerError.self) {
            _ = try selectAudioStreamDemuxer(headers: ["icy-metaint": "not-a-number"])
        }
    }
}

// MARK: - ImagePipeline, Decoding, Scaling, Transforms & OptimizedBuffer Rasterizer Tests

@Suite("ImagePipelineTests")
struct ImagePipelineTests {
    private func make2x2TestImage() throws -> NativeImage {
        // (0,0)=Red, (1,0)=Green, (0,1)=Blue, (1,1)=White
        let pixels: [UInt8] = [
            255, 0, 0, 255,     0, 255, 0, 255,
            0, 0, 255, 255,     255, 255, 255, 255,
        ]
        return try NativeImage.fromRgba(pixels, width: 2, height: 2)
    }

    @Test("PPM, BMP, and uncompressed PNG encode/decode round-trip and imageInfo probing")
    func formatCodecsAndProbing() throws {
        let img = try make2x2TestImage()

        // PNG round-trip
        let pngBytes = try img.encodePNG()
        let pngMeta = try imageInfo(pngBytes)
        #expect(pngMeta.format == .png)
        #expect(pngMeta.width == 2 && pngMeta.height == 2)
        #expect(pngMeta.hasAlpha)
        let fromPng = try NativeImage.decode(pngBytes)
        #expect(fromPng.rgbaBytes == img.rgbaBytes)

        // BMP 32-bit round-trip
        let bmpBytes = try img.encodeBMP(includeAlpha: true)
        let bmpMeta = try imageInfo(bmpBytes)
        #expect(bmpMeta.format == .bmp)
        #expect(bmpMeta.width == 2 && bmpMeta.height == 2)
        let fromBmp = try NativeImage.decode(bmpBytes)
        #expect(fromBmp.rgbaBytes == img.rgbaBytes)

        // PPM P6 round-trip
        let ppmBytes = try img.encodePPM()
        let ppmMeta = try imageInfo(ppmBytes)
        #expect(ppmMeta.format == .ppm)
        #expect(ppmMeta.width == 2 && ppmMeta.height == 2)
        let fromPpm = try NativeImage.decode(ppmBytes)
        #expect(fromPpm.rgbaBytes == img.rgbaBytes)

        // ASCII P3 PPM decoding with comments
        let asciiPpm = Array("P3\n# comment line\n2 1\n255\n10 20 30 40 50 60\n".utf8)
        let fromAscii = try NativeImage.decode(asciiPpm)
        #expect(fromAscii.width == 2 && fromAscii.height == 1)
        #expect(fromAscii.pixel(x: 0, y: 0) == RGBA.fromInts(10, 20, 30, 255))
        #expect(fromAscii.pixel(x: 1, y: 0) == RGBA.fromInts(40, 50, 60, 255))
    }

    @Test("Resize, crop, extend, rotate, flip/flop, composite, aspect layout, and image pool")
    func transformsAndAspectLayout() throws {
        let img = try make2x2TestImage()

        // Nearest & bilinear resize
        let nearest = try img.resize(ResizeOptions(width: 4, height: 4, kernel: .nearest))
        #expect(nearest.width == 4 && nearest.height == 4)
        #expect(nearest.pixel(x: 0, y: 0) == RGBA.fromInts(255, 0, 0, 255))
        #expect(nearest.pixel(x: 3, y: 0) == RGBA.fromInts(0, 255, 0, 255))

        let bilinear = try img.resize(ResizeOptions(width: 4, kernel: .triangle))
        #expect(bilinear.width == 4 && bilinear.height == 4)

        // Extract (crop)
        let cropped = try nearest.extract(ExtractOptions(left: 2, top: 2, width: 2, height: 2))
        #expect(cropped.width == 2 && cropped.height == 2)
        #expect(cropped.pixel(x: 0, y: 0) == RGBA.fromInts(255, 255, 255, 255))

        // Rotate 90 clockwise: (0,0) Red moves to (1,0)
        let rot90 = try img.rotate(90)
        #expect(rot90.width == 2 && rot90.height == 2)
        #expect(rot90.pixel(x: 1, y: 0) == RGBA.fromInts(255, 0, 0, 255))
        #expect(rot90.pixel(x: 0, y: 0) == RGBA.fromInts(0, 0, 255, 255))

        // Vertical flip & horizontal flop
        let flipped = try img.flip()
        #expect(flipped.pixel(x: 0, y: 0) == RGBA.fromInts(0, 0, 255, 255))
        let flopped = try img.flop()
        #expect(flopped.pixel(x: 0, y: 0) == RGBA.fromInts(0, 255, 0, 255))

        // Extend & composite
        let extended = try img.extend(ExtendOptions(top: 1, right: 1, bottom: 1, left: 1, background: (10, 20, 30, 255)))
        #expect(extended.width == 4 && extended.height == 4)
        #expect(extended.pixel(x: 0, y: 0) == RGBA.fromInts(10, 20, 30, 255))
        #expect(extended.pixel(x: 1, y: 1) == RGBA.fromInts(255, 0, 0, 255))

        let overlay = try NativeImage.solid(width: 2, height: 2, color: RGBA.fromInts(0, 0, 255, 128))
        let composited = try img.composite(overlay, options: CompositeOptions(left: 0, top: 0, blend: .sourceOver, opacity: 1.0))
        let blendedTopLeft = composited.pixel(x: 0, y: 0).toInts()
        #expect(blendedTopLeft.0 > 100 && blendedTopLeft.2 > 100)

        // Aspect layout math
        let fitLayout = computeImageAspectLayout(sourceWidth: 100, sourceHeight: 50, targetWidth: 20, targetHeight: 20, mode: .fit, cellAspectRatio: 1.0)
        #expect(fitLayout.destWidth == 20 && fitLayout.destHeight == 10)
        #expect(fitLayout.offsetX == 0 && fitLayout.offsetY == 5)

        let coverLayout = computeImageAspectLayout(sourceWidth: 100, sourceHeight: 50, targetWidth: 20, targetHeight: 20, mode: .cover, cellAspectRatio: 1.0)
        #expect(coverLayout.destWidth == 20 && coverLayout.destHeight == 20)
        #expect(coverLayout.sourceCrop.width == 50 && coverLayout.sourceCrop.left == 25)

        // Pool publish & reuse
        let pool = try NativeImagePool(options: NativeImagePoolOptions(width: 2, height: 2, capacity: 2))
        let frame1 = try #require(try pool.publishRgba(img.rgbaBytes))
        #expect(frame1.width == 2 && frame1.height == 2)
        pool.dispose()

        // takeRaw transfers pixels and marks image disposed
        let owned = try img.takeRaw()
        #expect(owned.data.count == 16)
        #expect(img.isDisposed)
        owned.dispose()
        #expect(owned.isDisposed)

        // BGRA import/export, RGB, grayscale, and area/cubic downscaling
        let bgraIn: [UInt8] = [10, 20, 30, 128, 40, 50, 60, 200]
        let fromBgra = try NativeImage.fromPixels(bgraIn, width: 2, height: 1, options: PixelImportOptions(format: .bgra8, alpha: .opaque))
        #expect(fromBgra.pixel(x: 0, y: 0) == RGBA.fromInts(30, 20, 10, 255))
        let bgraOut = try fromBgra.raw(format: .bgra8)
        #expect(bgraOut.data[0] == 10 && bgraOut.data[1] == 20 && bgraOut.data[2] == 30 && bgraOut.data[3] == 255)

        let fromGray = try NativeImage.fromGrayscale([0, 128, 255, 64], width: 2, height: 2)
        let downArea = try fromGray.resize(ResizeOptions(width: 1, height: 1, kernel: .area))
        #expect(downArea.width == 1 && downArea.height == 1)
        let upCubic = try fromGray.resize(ResizeOptions(width: 4, height: 4, kernel: .catmullRom))
        #expect(upCubic.width == 4 && upCubic.height == 4)
    }

    @Test("NativeImage.load handles bytes, file reader, URL fetcher, and error codes")
    func imageAsyncLoad() async throws {
        let base = try make2x2TestImage()
        let pngBytes = try base.encodePNG()

        let fromBytes = try await NativeImage.load(.bytes(pngBytes))
        #expect(fromBytes.width == 2 && fromBytes.height == 2)

        let fromUrl = try await NativeImage.load(
            .url("https://example.test/img.png"),
            options: ImageLoadOptions(fetch: { _ in ImageFetchResponse(status: 200, bytes: pngBytes) })
        )
        #expect(fromUrl.rgbaBytes == base.rgbaBytes)

        await #expect(throws: ImageLoadError.self) {
            _ = try await NativeImage.load(.url("ftp://example.test/img.png"))
        }
        await #expect(throws: ImageLoadError.self) {
            _ = try await NativeImage.load(
                .url("https://example.test/missing.png"),
                options: ImageLoadOptions(fetch: { _ in ImageFetchResponse(status: 404, bytes: []) })
            )
        }
    }

    @Test("Half-block, quadrant-block, and braille rasterizers draw directly into OptimizedBuffer")
    func bufferRasterizers() throws {
        // 4x4 image: top half red, bottom half blue
        var pixels: [UInt8] = []
        for y in 0..<4 {
            for _ in 0..<4 {
                if y < 2 {
                    pixels.append(contentsOf: [255, 0, 0, 255])
                } else {
                    pixels.append(contentsOf: [0, 0, 255, 255])
                }
            }
        }
        let img = try NativeImage.fromRgba(pixels, width: 4, height: 4)

        // Half-block rasterizer: 4x1 cell buffer -> each cell has top=red, bottom=blue -> '▀' (U+2580)
        let halfBuf = try OptimizedBuffer.create(width: 4, height: 1)
        ImageBufferRasterizer.renderHalfBlocks(img, into: halfBuf, x: 0, y: 0, width: 4, height: 1, mode: .fill, cellAspectRatio: 1.0)
        let cell0 = try #require(halfBuf.cell(atX: 0, y: 0))
        #expect(cell0.scalar == 0x2580) // '▀'
        #expect(cell0.foreground == RGBA.fromInts(255, 0, 0, 255))
        #expect(cell0.background == RGBA.fromInts(0, 0, 255, 255))

        // Quadrant rasterizer: 2x1 cells for 4x4 image -> top-half block '▀' or equivalent 2-color partition
        let quadBuf = try OptimizedBuffer.create(width: 2, height: 1)
        ImageBufferRasterizer.renderQuadrants(img, into: quadBuf, x: 0, y: 0, width: 2, height: 1, mode: .fill, cellAspectRatio: 1.0)
        let qCell = try #require(quadBuf.cell(atX: 0, y: 0))
        #expect(qCell.scalar == 0x2580 || qCell.scalar == 0x2584)

        // Braille rasterizer: bright white 2x4 image -> all 8 dots lit (U+28FF)
        let white = try NativeImage.solid(width: 2, height: 4, color: RGBA.fromInts(255, 255, 255, 255))
        let brailleBuf = try OptimizedBuffer.create(width: 1, height: 1)
        ImageBufferRasterizer.renderBraille(white, into: brailleBuf, x: 0, y: 0, width: 1, height: 1, mode: .fill, threshold: 128, cellAspectRatio: 1.0)
        let bCell = try #require(brailleBuf.cell(atX: 0, y: 0))
        #expect(bCell.scalar == 0x28FF)
    }
}

// MARK: - Kitty Graphics Protocol APC Encoder Tests

@Suite("KittyImageEncoderTests")
struct KittyImageEncoderTests {
    @Test("Pure-Swift Base64 and chunked Kitty APC framing for RGBA and PNG")
    func kittyChunkingAndDelete() throws {
        #expect(encodeImageBase64(Array("Man".utf8)) == "TWFu")
        #expect(encodeImageBase64(Array("Ma".utf8)) == "TWE=")
        #expect(encodeImageBase64(Array("M".utf8)) == "TQ==")

        let img = try NativeImage.solid(width: 4, height: 4, color: RGBA.fromInts(12, 34, 56, 255))
        // Force multi-chunk output with tiny chunkSize = 16
        let seq = try KittyImageEncoder.encode(img, format: .rgba32, cols: 4, rows: 2, imageId: 42, placementId: 7, chunkSize: 16)
        #expect(seq.hasPrefix("\u{1B}_Ga=T,f=32,s=4,v=4,c=4,r=2,i=42,p=7,q=2,m=1;"))
        #expect(seq.contains("\u{1B}_Gm=1;"))
        #expect(seq.contains("\u{1B}_Gm=0;"))
        #expect(seq.hasSuffix("\u{1B}\\"))

        let pngSeq = try KittyImageEncoder.encode(img, format: .png, imageId: 9, chunkSize: 4096)
        #expect(pngSeq.hasPrefix("\u{1B}_Ga=T,f=100,i=9,q=2,m=0;"))
        #expect(pngSeq.hasSuffix("\u{1B}\\"))

        #expect(KittyImageEncoder.delete(imageId: 42) == "\u{1B}_Ga=d,d=I,i=42,q=2\u{1B}\\")
        #expect(KittyImageEncoder.delete() == "\u{1B}_Ga=d,d=a,q=2\u{1B}\\")
    }
}

// MARK: - Sixel Encoder Tests

@Suite("SixelEncoderTests")
struct SixelEncoderTests {
    @Test("Sixel encoder produces valid DCS framing, palette registers, RLE runs, and >256 color quantization")
    func sixelEncodingAndQuantization() throws {
        // 12x12 image: top 6 rows red, bottom 6 rows green -> triggers RLE (!12~) and 2 bands separated by '-'
        var pixels: [UInt8] = []
        for y in 0..<12 {
            for _ in 0..<12 {
                if y < 6 {
                    pixels.append(contentsOf: [255, 0, 0, 255])
                } else {
                    pixels.append(contentsOf: [0, 255, 0, 255])
                }
            }
        }
        let img = try NativeImage.fromRgba(pixels, width: 12, height: 12)
        let sixel = try SixelEncoder.encode(img, maxColors: 16)

        #expect(sixel.hasPrefix("\u{1B}P0;1;0q\"1;1;12;12"))
        #expect(sixel.contains("#0;2;100;0;0"))
        #expect(sixel.contains("#1;2;0;100;0"))
        #expect(sixel.contains("!12~")) // 12 consecutive full 6-row columns (63 + 63 = 126 = '~')
        #expect(sixel.contains("-"))    // band separator
        #expect(sixel.hasSuffix("\u{1B}\\"))

        // Stress test quantization with 300 distinct colors (exceeding 256 limit)
        var gradient: [UInt8] = []
        for y in 0..<20 {
            for x in 0..<20 {
                gradient.append(UInt8((x * 13) & 0xFF))
                gradient.append(UInt8((y * 13) & 0xFF))
                gradient.append(UInt8(((x + y) * 7) & 0xFF))
                gradient.append(255)
            }
        }
        let gradImg = try NativeImage.fromRgba(gradient, width: 20, height: 20)
        let quantized = try SixelEncoder.encode(gradImg, maxColors: 64)
        #expect(quantized.hasPrefix("\u{1B}P0;1;0q\"1;1;20;20"))
        #expect(quantized.hasSuffix("\u{1B}\\"))
    }
}

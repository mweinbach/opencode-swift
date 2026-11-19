/// Pure-Swift PCM audio engine, mixer graph, procedural synthesizer, WAV codec, FFT/RMS meter,
/// capture ring buffer, and streaming playback controller matching `packages/core/src/audio.ts`.

// MARK: - Pure-Swift Math & Deterministic PRNG Helpers

private let audioTwoPi: Double = 2.0 * Double.pi
private let audioHalfPi: Double = Double.pi / 2.0
private let audioLn2: Double = 0.693147180559945309417232121458176568
private let audioLn10: Double = 2.302585092994045684017991454684364208

private func audioSin(_ x: Double) -> Double {
    if !x.isFinite { return .nan }
    var reduced = x.truncatingRemainder(dividingBy: audioTwoPi)
    if reduced > Double.pi { reduced -= audioTwoPi }
    if reduced < -Double.pi { reduced += audioTwoPi }

    if reduced > audioHalfPi {
        reduced = Double.pi - reduced
    } else if reduced < -audioHalfPi {
        reduced = -Double.pi - reduced
    }

    let x2 = reduced * reduced
    var term = reduced
    var sum = reduced
    for k in 1...10 {
        let denom = Double((2 * k) * (2 * k + 1))
        term = -term * x2 / denom
        sum += term
    }
    return sum
}

private func audioCos(_ x: Double) -> Double {
    audioSin(x + audioHalfPi)
}

private func audioExp(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    if x > 709.782712893384 { return .infinity }
    if x < -745.1332191019412 { return 0.0 }

    let k = Int((x / audioLn2).rounded())
    let r = x - Double(k) * audioLn2

    var term = 1.0
    var sum = 1.0
    for n in 1...18 {
        term *= r / Double(n)
        sum += term
    }
    return sum * Double(sign: .plus, exponent: k, significand: 1.0)
}

private func audioLn(_ x: Double) -> Double {
    if x.isNaN || x < 0.0 { return .nan }
    if x == 0.0 { return -.infinity }
    if x == .infinity { return .infinity }

    var exp = x.exponent
    var m = x.significand
    if m > 1.4142135623730951 {
        m *= 0.5
        exp += 1
    }
    let u = (m - 1.0) / (m + 1.0)
    let u2 = u * u
    var term = u
    var sum = u
    for k in 1...14 {
        term *= u2
        sum += term / Double(2 * k + 1)
    }
    return 2.0 * sum + Double(exp) * audioLn2
}

private func audioLog10(_ x: Double) -> Double {
    audioLn(x) / audioLn10
}

private func audioPow(_ base: Double, _ exponent: Double) -> Double {
    if exponent == 0.0 { return 1.0 }
    if base == 1.0 { return 1.0 }
    if base.isNaN || exponent.isNaN { return .nan }
    if base == 0.0 {
        if exponent > 0.0 { return 0.0 }
        return .infinity
    }
    if base < 0.0 {
        let rounded = exponent.rounded()
        if rounded == exponent {
            let mag = audioExp(exponent * audioLn(-base))
            let isOdd = Int(rounded.truncatingRemainder(dividingBy: 2.0)) != 0
            return isOdd ? -mag : mag
        }
        return .nan
    }
    return audioExp(exponent * audioLn(base))
}

private struct AudioSplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Float in `[-1.0, 1.0]`.
    mutating func nextBipolarFloat() -> Float {
        let unit = Double(nextUInt64() >> 11) * (1.0 / Double(UInt64(1) << 53))
        return Float(unit * 2.0 - 1.0)
    }
}

// MARK: - PCM Format Types, Buffers, Converters & WAV Codec

/// Sample encoding formats supported for PCM conversion and WAV I/O.
public enum AudioSampleFormat: String, Equatable, Hashable, Sendable, CaseIterable {
    case float32 = "f32le"
    case int16 = "s16le"
    case int24 = "s24le"
    case uint8 = "u8"

    public var bytesPerSample: Int {
        switch self {
        case .float32: return 4
        case .int16: return 2
        case .int24: return 3
        case .uint8: return 1
        }
    }
}

/// Speaker channel layout descriptor.
public enum AudioChannelLayout: Equatable, Hashable, Sendable {
    case mono
    case stereo
    case surround51
    case custom(Int)

    public var channelCount: Int {
        switch self {
        case .mono: return 1
        case .stereo: return 2
        case .surround51: return 6
        case .custom(let n): return max(1, n)
        }
    }
}

/// Immutable interleaved float32 PCM audio buffer.
public struct AudioPCMBuffer: Equatable, Sendable {
    public let sampleRate: Int
    public let channels: Int
    public var samples: [Float]

    public init(sampleRate: Int, channels: Int, samples: [Float]) {
        self.sampleRate = max(1, sampleRate)
        self.channels = max(1, channels)
        self.samples = samples
    }

    /// Creates a silent buffer of `frameCount` frames.
    public static func silence(sampleRate: Int = 48_000, channels: Int = 2, frameCount: Int) -> AudioPCMBuffer {
        let safeChannels = max(1, channels)
        let safeFrames = max(0, frameCount)
        return AudioPCMBuffer(
            sampleRate: sampleRate,
            channels: safeChannels,
            samples: Array(repeating: 0, count: safeFrames * safeChannels)
        )
    }

    public var frameCount: Int {
        samples.count / channels
    }

    public var duration: Double {
        Double(frameCount) / Double(sampleRate)
    }

    /// Reads sample at `(frame, channel)`, returning `0` if out of bounds.
    public func sample(frame: Int, channel: Int) -> Float {
        guard frame >= 0 && frame < frameCount && channel >= 0 && channel < channels else { return 0 }
        return samples[frame * channels + channel]
    }

    /// Extracts a single deinterleaved channel.
    public func channelSamples(_ channel: Int) -> [Float] {
        guard channel >= 0 && channel < channels else { return [] }
        let frames = frameCount
        var result: [Float] = []
        result.reserveCapacity(frames)
        for frame in 0..<frames {
            result.append(samples[frame * channels + channel])
        }
        return result
    }

    /// Peak absolute amplitude across all samples.
    public func peakLevel() -> Float {
        AudioLevelMeter.measure(samples).peak
    }

    /// Root-mean-square amplitude across all samples.
    public func rmsLevel() -> Float {
        AudioLevelMeter.measure(samples).rms
    }

    /// RMS amplitude in dBFS (clamped at `-120.0` for silence).
    public func rmsDecibels() -> Double {
        AudioLevelMeter.measure(samples).rmsDb
    }

    /// Returns a linearly resampled copy at `targetSampleRate`.
    public func resampled(to targetSampleRate: Int) -> AudioPCMBuffer {
        let safeRate = max(1, targetSampleRate)
        if safeRate == sampleRate || frameCount == 0 {
            return self
        }
        let ratio = Double(sampleRate) / Double(safeRate)
        let outFrames = max(1, Int((Double(frameCount) / ratio).rounded()))
        var out = Array<Float>(repeating: 0, count: outFrames * channels)
        let maxSrc = frameCount - 1
        for f in 0..<outFrames {
            let srcPos = Double(f) * ratio
            let i0 = min(maxSrc, Int(srcPos))
            let i1 = min(maxSrc, i0 + 1)
            let frac = Float(srcPos - Double(i0))
            for ch in 0..<channels {
                let s0 = samples[i0 * channels + ch]
                let s1 = samples[i1 * channels + ch]
                out[f * channels + ch] = s0 + (s1 - s0) * frac
            }
        }
        return AudioPCMBuffer(sampleRate: safeRate, channels: channels, samples: out)
    }
}

/// Pure-Swift PCM sample conversion helpers (float32 <-> int16 & little-endian byte serialization).
public enum PCMConverter {
    @inline(__always)
    public static func clampSample(_ sample: Float) -> Float {
        guard sample.isFinite else { return 0 }
        return max(-1.0, min(1.0, sample))
    }

    /// Converts normalized float32 samples (`[-1, 1]`) to signed 16-bit PCM (`Int16`).
    public static func float32ToInt16(_ samples: [Float]) -> [Int16] {
        var out: [Int16] = []
        out.reserveCapacity(samples.count)
        for sample in samples {
            let clamped = clampSample(sample)
            let scaled = (Double(clamped) * 32767.0).rounded()
            let clampedInt = max(-32768, min(32767, Int(scaled)))
            out.append(Int16(clampedInt))
        }
        return out
    }

    /// Converts signed 16-bit PCM (`Int16`) samples to normalized float32 (`[-1, 1]`).
    public static func int16ToFloat32(_ samples: [Int16]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(samples.count)
        for sample in samples {
            if sample == Int16.min {
                out.append(-1.0)
            } else {
                out.append(Float(sample) / 32767.0)
            }
        }
        return out
    }

    /// Encodes normalized float32 samples to little-endian signed 16-bit PCM bytes.
    public static func float32ToInt16BytesLE(_ samples: [Float]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = clampSample(sample)
            let scaled = (Double(clamped) * 32767.0).rounded()
            let val = Int16(max(-32768, min(32767, Int(scaled))))
            let bits = UInt16(bitPattern: val)
            bytes.append(UInt8(bits & 0xFF))
            bytes.append(UInt8((bits >> 8) & 0xFF))
        }
        return bytes
    }

    /// Decodes little-endian signed 16-bit PCM bytes to normalized float32 samples.
    public static func int16BytesLEToFloat32(_ bytes: [UInt8]) -> [Float] {
        let count = bytes.count / 2
        var out: [Float] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let lo = UInt16(bytes[i * 2])
            let hi = UInt16(bytes[i * 2 + 1])
            let val = Int16(bitPattern: lo | (hi << 8))
            out.append(val == Int16.min ? -1.0 : Float(val) / 32767.0)
        }
        return out
    }

    /// Encodes float32 samples to little-endian IEEE 754 bytes (`f32le`).
    public static func float32ToBytesLE(_ samples: [Float]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(samples.count * 4)
        for sample in samples {
            let bits = sample.bitPattern
            bytes.append(UInt8(bits & 0xFF))
            bytes.append(UInt8((bits >> 8) & 0xFF))
            bytes.append(UInt8((bits >> 16) & 0xFF))
            bytes.append(UInt8((bits >> 24) & 0xFF))
        }
        return bytes
    }

    /// Decodes little-endian IEEE 754 bytes (`f32le`) to float32 samples.
    public static func bytesLEToFloat32(_ bytes: [UInt8]) -> [Float] {
        let count = bytes.count / 4
        var out: [Float] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let b0 = UInt32(bytes[i * 4])
            let b1 = UInt32(bytes[i * 4 + 1]) << 8
            let b2 = UInt32(bytes[i * 4 + 2]) << 16
            let b3 = UInt32(bytes[i * 4 + 3]) << 24
            out.append(Float(bitPattern: b0 | b1 | b2 | b3))
        }
        return out
    }
}

/// Errors thrown while encoding or decoding RIFF WAVE PCM data.
public enum WAVError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case tooShort
    case invalidHeader
    case unsupportedFormat(UInt16)
    case unsupportedBitDepth(UInt16)
    case invalidChannelCount(Int)
    case invalidSampleRate(Int)
    case missingFormatChunk
    case missingDataChunk
    case truncatedData
    case exceedsRiffLimit

    public var description: String {
        switch self {
        case .tooShort: return "WAV data is too short"
        case .invalidHeader: return "Invalid RIFF/WAVE header"
        case .unsupportedFormat(let fmt): return "Unsupported WAV audio format tag: \(fmt)"
        case .unsupportedBitDepth(let bits): return "Unsupported WAV bit depth: \(bits)"
        case .invalidChannelCount(let ch): return "Invalid WAV channel count: \(ch)"
        case .invalidSampleRate(let sr): return "Invalid WAV sample rate: \(sr)"
        case .missingFormatChunk: return "WAV stream missing 'fmt ' chunk"
        case .missingDataChunk: return "WAV stream missing 'data' chunk"
        case .truncatedData: return "WAV data chunk is truncated"
        case .exceedsRiffLimit: return "WAV payload exceeds classic 32-bit RIFF size limit"
        }
    }
}

private let wavHeaderBytes = 44
private let maxWavDataBytes: UInt64 = UInt64(UInt32.max) - 36

/// Pure-Swift RIFF WAVE PCM encoder and decoder (8/16/24-bit integer PCM and 32-bit IEEE float PCM).
public enum WAVCodec {
    private static func readU16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readU32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func appendU16LE(_ value: UInt16, to out: inout [UInt8]) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendU32LE(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    }

    /// Builds a 44-byte canonical RIFF WAVE header matching `core/src/audio.ts#createWavHeader`.
    public static func createHeader(
        sampleRate: Int,
        channels: Int,
        dataBytes: Int,
        bitsPerSample: Int = 16,
        isFloat: Bool = false
    ) -> [UInt8] {
        let bytesPerSample = max(1, bitsPerSample / 8)
        let blockAlign = UInt16(clamping: channels * bytesPerSample)
        let byteRate = UInt32(clamping: sampleRate * channels * bytesPerSample)
        let riffSize = UInt32(clamping: dataBytes + 36)
        let audioFormat: UInt16 = isFloat ? 3 : 1

        var header: [UInt8] = []
        header.reserveCapacity(wavHeaderBytes)
        header.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendU32LE(riffSize, to: &header)
        header.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"
        header.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        appendU32LE(16, to: &header)
        appendU16LE(audioFormat, to: &header)
        appendU16LE(UInt16(clamping: channels), to: &header)
        appendU32LE(UInt32(clamping: sampleRate), to: &header)
        appendU32LE(byteRate, to: &header)
        appendU16LE(blockAlign, to: &header)
        appendU16LE(UInt16(clamping: bitsPerSample), to: &header)
        header.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        appendU32LE(UInt32(clamping: dataBytes), to: &header)
        return header
    }

    /// Encodes an `AudioPCMBuffer` into RIFF WAVE bytes (16-bit integer PCM by default, or 32-bit float PCM).
    public static func encode(
        _ buffer: AudioPCMBuffer,
        bitsPerSample: Int = 16,
        asFloat: Bool = false
    ) throws(WAVError) -> [UInt8] {
        guard buffer.channels >= 1 && buffer.channels <= 64 else {
            throw .invalidChannelCount(buffer.channels)
        }
        guard buffer.sampleRate >= 1 else {
            throw .invalidSampleRate(buffer.sampleRate)
        }
        let payload: [UInt8]
        let actualBits: Int
        if asFloat {
            actualBits = 32
            payload = PCMConverter.float32ToBytesLE(buffer.samples)
        } else if bitsPerSample == 16 {
            actualBits = 16
            payload = PCMConverter.float32ToInt16BytesLE(buffer.samples)
        } else if bitsPerSample == 8 {
            actualBits = 8
            var bytes: [UInt8] = []
            bytes.reserveCapacity(buffer.samples.count)
            for s in buffer.samples {
                let c = PCMConverter.clampSample(s)
                bytes.append(UInt8(max(0, min(255, Int(((Double(c) + 1.0) * 127.5).rounded())))))
            }
            payload = bytes
        } else {
            throw .unsupportedBitDepth(UInt16(clamping: bitsPerSample))
        }

        guard UInt64(payload.count) <= maxWavDataBytes else {
            throw .exceedsRiffLimit
        }

        var result = createHeader(
            sampleRate: buffer.sampleRate,
            channels: buffer.channels,
            dataBytes: payload.count,
            bitsPerSample: actualBits,
            isFloat: asFloat
        )
        result.append(contentsOf: payload)
        return result
    }

    /// Decodes RIFF WAVE bytes into an `AudioPCMBuffer`.
    public static func decode(_ bytes: [UInt8]) throws(WAVError) -> AudioPCMBuffer {
        guard bytes.count >= wavHeaderBytes else {
            throw .tooShort
        }
        // Check "RIFF" ... "WAVE"
        guard bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46,
              bytes[8] == 0x57 && bytes[9] == 0x41 && bytes[10] == 0x56 && bytes[11] == 0x45
        else {
            throw .invalidHeader
        }

        var offset = 12
        var audioFormat: UInt16? = nil
        var channels: Int = 0
        var sampleRate: Int = 0
        var bitsPerSample: UInt16 = 0
        var dataRange: Range<Int>? = nil

        while offset + 8 <= bytes.count {
            let id0 = bytes[offset]
            let id1 = bytes[offset + 1]
            let id2 = bytes[offset + 2]
            let id3 = bytes[offset + 3]
            let chunkSize = Int(readU32LE(bytes, at: offset + 4))
            let chunkDataStart = offset + 8
            let chunkDataEnd = chunkDataStart + chunkSize

            if id0 == 0x66 && id1 == 0x6D && id2 == 0x74 && id3 == 0x20 { // "fmt "
                guard chunkSize >= 16, chunkDataEnd <= bytes.count else {
                    throw .truncatedData
                }
                audioFormat = readU16LE(bytes, at: chunkDataStart)
                channels = Int(readU16LE(bytes, at: chunkDataStart + 2))
                sampleRate = Int(readU32LE(bytes, at: chunkDataStart + 4))
                bitsPerSample = readU16LE(bytes, at: chunkDataStart + 14)
            } else if id0 == 0x64 && id1 == 0x61 && id2 == 0x74 && id3 == 0x61 { // "data"
                let clampedEnd = min(bytes.count, chunkDataEnd)
                if chunkDataStart > bytes.count {
                    throw .truncatedData
                }
                dataRange = chunkDataStart..<clampedEnd
                break
            }

            let paddedSize = chunkSize + (chunkSize & 1)
            let next = chunkDataStart + paddedSize
            if next <= offset { break }
            offset = next
        }

        guard let fmt = audioFormat else { throw .missingFormatChunk }
        guard fmt == 1 || fmt == 3 else { throw .unsupportedFormat(fmt) }
        guard channels >= 1 else { throw .invalidChannelCount(channels) }
        guard sampleRate >= 1 else { throw .invalidSampleRate(sampleRate) }
        guard let range = dataRange else { throw .missingDataChunk }

        let payload = Array(bytes[range])
        let samples: [Float]

        if fmt == 3 {
            guard bitsPerSample == 32 else { throw .unsupportedBitDepth(bitsPerSample) }
            samples = PCMConverter.bytesLEToFloat32(payload)
        } else {
            switch bitsPerSample {
            case 8:
                samples = payload.map { (Float($0) - 128.0) / 128.0 }
            case 16:
                samples = PCMConverter.int16BytesLEToFloat32(payload)
            case 24:
                let sampleCount = payload.count / 3
                var decoded: [Float] = []
                decoded.reserveCapacity(sampleCount)
                for i in 0..<sampleCount {
                    let b0 = Int32(payload[i * 3])
                    let b1 = Int32(payload[i * 3 + 1]) << 8
                    let b2 = Int32(payload[i * 3 + 2]) << 16
                    var raw = b0 | b1 | b2
                    if (raw & 0x0080_0000) != 0 {
                        raw |= Int32(bitPattern: 0xFF00_0000)
                    }
                    decoded.append(Float(raw) / 8388608.0)
                }
                samples = decoded
            case 32:
                let sampleCount = payload.count / 4
                var decoded: [Float] = []
                decoded.reserveCapacity(sampleCount)
                for i in 0..<sampleCount {
                    let u = readU32LE(payload, at: i * 4)
                    let val = Int32(bitPattern: u)
                    decoded.append(Float(Double(val) / 2147483648.0))
                }
                samples = decoded
            default:
                throw .unsupportedBitDepth(bitsPerSample)
            }
        }

        return AudioPCMBuffer(sampleRate: sampleRate, channels: channels, samples: samples)
    }
}

// MARK: - Procedural Waveform Synthesizer

/// Procedural oscillator & noise waveforms supported by `AudioSynthesizer`.
public enum WaveformType: String, Equatable, Hashable, Sendable, CaseIterable {
    case sine
    case square
    case triangle
    case sawtooth
    case whiteNoise
    case pinkNoise
}

/// Pure-Swift procedural waveform generator and ADSR envelope processor.
public enum AudioSynthesizer {
    /// Generates an interleaved float32 `AudioPCMBuffer` for the requested waveform.
    public static func generate(
        waveform: WaveformType,
        frequency: Double = 440.0,
        duration: Double,
        sampleRate: Int = 48_000,
        channels: Int = 1,
        amplitude: Float = 0.8,
        phase: Double = 0.0,
        seed: UInt64 = 0x1234_5678_9ABC_DEF0
    ) -> AudioPCMBuffer {
        let safeRate = max(1, sampleRate)
        let safeChannels = max(1, channels)
        let frameCount = max(0, Int((max(0.0, duration) * Double(safeRate)).rounded()))
        var samples: [Float] = []
        samples.reserveCapacity(frameCount * safeChannels)

        var prng = AudioSplitMix64(seed: seed)
        // Paul Kellet's pink noise filter state
        var b0: Double = 0, b1: Double = 0, b2: Double = 0
        var b3: Double = 0, b4: Double = 0, b5: Double = 0, b6: Double = 0

        let amp = Double(amplitude)
        let phaseInc = frequency / Double(safeRate)

        for frame in 0..<frameCount {
            let rawPhase = phase + Double(frame) * phaseInc
            let frac = rawPhase - rawPhase.rounded(.down)
            let value: Double

            switch waveform {
            case .sine:
                value = audioSin(audioTwoPi * rawPhase)
            case .square:
                value = frac < 0.5 ? 1.0 : -1.0
            case .triangle:
                if frac < 0.25 {
                    value = 4.0 * frac
                } else if frac < 0.75 {
                    value = 2.0 - 4.0 * frac
                } else {
                    value = 4.0 * frac - 4.0
                }
            case .sawtooth:
                value = 2.0 * frac - 1.0
            case .whiteNoise:
                value = Double(prng.nextBipolarFloat())
            case .pinkNoise:
                let white = Double(prng.nextBipolarFloat())
                b0 = 0.99886 * b0 + white * 0.0555179
                b1 = 0.99332 * b1 + white * 0.0750759
                b2 = 0.96900 * b2 + white * 0.1538520
                b3 = 0.86650 * b3 + white * 0.3104856
                b4 = 0.55000 * b4 + white * 0.5329522
                b5 = -0.7616 * b5 - white * 0.0168980
                let pink = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362) * 0.11
                b6 = white * 0.115926
                value = max(-1.0, min(1.0, pink))
            }

            let scaled = Float(value * amp)
            for _ in 0..<safeChannels {
                samples.append(scaled)
            }
        }

        return AudioPCMBuffer(sampleRate: safeRate, channels: safeChannels, samples: samples)
    }

    /// Applies a linear Attack-Decay-Sustain-Release envelope to a PCM buffer.
    public static func applyEnvelope(
        _ buffer: AudioPCMBuffer,
        attack: Double,
        decay: Double,
        sustain: Float,
        release: Double
    ) -> AudioPCMBuffer {
        let frames = buffer.frameCount
        guard frames > 0 else { return buffer }
        let sr = Double(buffer.sampleRate)
        let attackFrames = max(0, Int((max(0, attack) * sr).rounded()))
        let decayFrames = max(0, Int((max(0, decay) * sr).rounded()))
        let releaseFrames = max(0, Int((max(0, release) * sr).rounded()))
        let releaseStart = max(0, frames - releaseFrames)
        let sustainLevel = max(0.0, min(1.0, sustain))

        var out = buffer.samples
        for frame in 0..<frames {
            var gain: Float
            if attackFrames > 0 && frame < attackFrames {
                gain = Float(frame) / Float(attackFrames)
            } else if decayFrames > 0 && frame < attackFrames + decayFrames {
                let t = Float(frame - attackFrames) / Float(decayFrames)
                gain = 1.0 + (sustainLevel - 1.0) * t
            } else {
                gain = sustainLevel
            }
            if releaseFrames > 0 && frame >= releaseStart {
                let t = Float(frame - releaseStart) / Float(releaseFrames)
                gain *= max(0.0, 1.0 - t)
            }
            for ch in 0..<buffer.channels {
                out[frame * buffer.channels + ch] *= gain
            }
        }
        return AudioPCMBuffer(sampleRate: buffer.sampleRate, channels: buffer.channels, samples: out)
    }
}

// MARK: - Pure-Swift Radix-2 FFT & RMS/Peak Level Metering

/// Instantaneous audio signal meter reading.
public struct AudioMeterReading: Equatable, Sendable {
    public let peak: Float
    public let rms: Float
    public let peakDb: Double
    public let rmsDb: Double
    public let clipping: Bool

    public init(peak: Float, rms: Float, peakDb: Double, rmsDb: Double, clipping: Bool) {
        self.peak = peak
        self.rms = rms
        self.peakDb = peakDb
        self.rmsDb = rmsDb
        self.clipping = clipping
    }
}

/// Pure-Swift peak and RMS level meter.
public enum AudioLevelMeter {
    public static let silenceFloorDb: Double = -120.0

    public static func linearToDecibels(_ value: Float) -> Double {
        let absVal = abs(Double(value))
        if absVal <= 1e-6 { return silenceFloorDb }
        return max(silenceFloorDb, 20.0 * audioLog10(absVal))
    }

    public static func decibelsToLinear(_ decibels: Double) -> Float {
        if decibels <= silenceFloorDb { return 0.0 }
        return Float(audioPow(10.0, decibels / 20.0))
    }

    public static func measure(_ samples: [Float]) -> AudioMeterReading {
        guard !samples.isEmpty else {
            return AudioMeterReading(peak: 0, rms: 0, peakDb: silenceFloorDb, rmsDb: silenceFloorDb, clipping: false)
        }
        var peak: Float = 0
        var sumSq: Double = 0
        for sample in samples {
            let a = abs(sample)
            if a > peak { peak = a }
            sumSq += Double(sample) * Double(sample)
        }
        let rms = Float((sumSq / Double(samples.count)).squareRoot())
        return AudioMeterReading(
            peak: peak,
            rms: rms,
            peakDb: linearToDecibels(peak),
            rmsDb: linearToDecibels(rms),
            clipping: peak >= 1.0
        )
    }
}

/// Pure-Swift Radix-2 Cooley-Tukey FFT analyzer for frequency spectrum metering.
public enum AudioFFT {
    /// Computes the normalized single-sided magnitude spectrum (`windowSize / 2 + 1` bins)
    /// of a mono sample slice using a Hann window. `windowSize` is rounded up to the next power of two.
    public static func magnitudeSpectrum(samples: [Float], windowSize: Int = 256) -> [Float] {
        var n = 2
        let requested = max(2, windowSize)
        while n < requested { n <<= 1 }

        var real = Array<Double>(repeating: 0.0, count: n)
        var imag = Array<Double>(repeating: 0.0, count: n)

        let copyCount = min(n, samples.count)
        let denom = Double(max(1, n - 1))
        for i in 0..<copyCount {
            let window = 0.5 * (1.0 - audioCos(audioTwoPi * Double(i) / denom))
            real[i] = Double(samples[i]) * window
        }

        // Bit-reversal permutation
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while (j & bit) != 0 {
                j ^= bit
                bit >>= 1
            }
            j ^= bit
            if i < j {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
        }

        // Cooley-Tukey butterflies
        var len = 2
        while len <= n {
            let halfLen = len >> 1
            let angle = -audioTwoPi / Double(len)
            let wLenRe = audioCos(angle)
            let wLenIm = audioSin(angle)
            var i = 0
            while i < n {
                var wRe = 1.0
                var wIm = 0.0
                for k in 0..<halfLen {
                    let uRe = real[i + k]
                    let uIm = imag[i + k]
                    let vRe = real[i + k + halfLen] * wRe - imag[i + k + halfLen] * wIm
                    let vIm = real[i + k + halfLen] * wIm + imag[i + k + halfLen] * wRe
                    real[i + k] = uRe + vRe
                    imag[i + k] = uIm + vIm
                    real[i + k + halfLen] = uRe - vRe
                    imag[i + k + halfLen] = uIm - vIm
                    let nextWRe = wRe * wLenRe - wIm * wLenIm
                    let nextWIm = wRe * wLenIm + wIm * wLenRe
                    wRe = nextWRe
                    wIm = nextWIm
                }
                i += len
            }
            len <<= 1
        }

        let binCount = (n / 2) + 1
        let scale = 2.0 / Double(n)
        var magnitudes: [Float] = []
        magnitudes.reserveCapacity(binCount)
        for k in 0..<binCount {
            let mag = (real[k] * real[k] + imag[k] * imag[k]).squareRoot() * scale
            magnitudes.append(Float(mag))
        }
        return magnitudes
    }

    /// Estimates the dominant frequency in Hz from the strongest non-DC FFT bin.
    public static func dominantFrequency(samples: [Float], sampleRate: Int, windowSize: Int = 1024) -> Double {
        let spectrum = magnitudeSpectrum(samples: samples, windowSize: windowSize)
        guard spectrum.count > 2 else { return 0.0 }
        let n = (spectrum.count - 1) * 2
        var bestBin = 1
        var bestMag: Float = -1
        for k in 1..<spectrum.count {
            if spectrum[k] > bestMag {
                bestMag = spectrum[k]
                bestBin = k
            }
        }
        guard bestMag > 0 else { return 0.0 }
        return Double(bestBin) * Double(sampleRate) / Double(n)
    }
}

// MARK: - Pluggable Audio Output Sink

/// Pluggable destination receiving mixed float32 PCM frames from the audio engine.
public protocol AudioOutputSink: AnyObject, Sendable {
    func writeFrames(_ samples: [Float], frameCount: Int, channels: Int, sampleRate: Int)
}

/// Deterministic in-memory PCM capture sink for cross-platform testing and headless rendering.
public final class MemoryAudioOutputSink: AudioOutputSink, @unchecked Sendable {
    public private(set) var samples: [Float] = []
    public private(set) var totalFramesWritten: Int = 0
    public private(set) var lastChannels: Int = 0
    public private(set) var lastSampleRate: Int = 0
    public private(set) var writeCallCount: Int = 0

    public init() {}

    public func writeFrames(_ samples: [Float], frameCount: Int, channels: Int, sampleRate: Int) {
        self.samples.append(contentsOf: samples)
        self.totalFramesWritten += frameCount
        self.lastChannels = channels
        self.lastSampleRate = sampleRate
        self.writeCallCount += 1
    }

    public func clear() {
        samples.removeAll()
        totalFramesWritten = 0
        writeCallCount = 0
    }

    public func asPCMBuffer() -> AudioPCMBuffer {
        AudioPCMBuffer(
            sampleRate: max(1, lastSampleRate),
            channels: max(1, lastChannels),
            samples: samples
        )
    }
}

/// Silent discard sink.
public final class NullAudioOutputSink: AudioOutputSink, Sendable {
    public init() {}
    public func writeFrames(_ samples: [Float], frameCount: Int, channels: Int, sampleRate: Int) {}
}

// MARK: - Upstream Audio Options, Identifiers & Metadata Types

// parity: core/src/audio.ts#AudioGroup [status=implemented hash=75bc277d040b]
public typealias AudioGroup = UInt32

// parity: core/src/audio.ts#AudioVoice [status=implemented hash=8ddacb8fe65f]
public typealias AudioVoice = UInt32

// parity: core/src/audio.ts#AudioSound [status=implemented hash=d7bc8d2c8999]
public typealias AudioSound = UInt32

// parity: core/src/audio.ts#AudioStartOptions [status=implemented hash=ca89a1e7ca2e]
public struct AudioStartOptions: Equatable, Hashable, Sendable {
    public var periodSizeInFrames: Int?
    public var periodSizeInMilliseconds: Int?
    public var periods: Int?
    public var performanceProfile: Int?
    public var shareMode: Int?
    public var noPreSilencedOutputBuffer: Bool?
    public var noClip: Bool?
    public var noDisableDenormals: Bool?
    public var noFixedSizedCallback: Bool?
    public var wasapiNoAutoConvertSrc: Bool?
    public var wasapiNoDefaultQualitySrc: Bool?
    public var alsaNoMMap: Bool?
    public var alsaNoAutoFormat: Bool?
    public var alsaNoAutoChannels: Bool?
    public var alsaNoAutoResample: Bool?

    public init(
        periodSizeInFrames: Int? = nil,
        periodSizeInMilliseconds: Int? = nil,
        periods: Int? = nil,
        performanceProfile: Int? = nil,
        shareMode: Int? = nil,
        noPreSilencedOutputBuffer: Bool? = nil,
        noClip: Bool? = nil,
        noDisableDenormals: Bool? = nil,
        noFixedSizedCallback: Bool? = nil,
        wasapiNoAutoConvertSrc: Bool? = nil,
        wasapiNoDefaultQualitySrc: Bool? = nil,
        alsaNoMMap: Bool? = nil,
        alsaNoAutoFormat: Bool? = nil,
        alsaNoAutoChannels: Bool? = nil,
        alsaNoAutoResample: Bool? = nil
    ) {
        self.periodSizeInFrames = periodSizeInFrames
        self.periodSizeInMilliseconds = periodSizeInMilliseconds
        self.periods = periods
        self.performanceProfile = performanceProfile
        self.shareMode = shareMode
        self.noPreSilencedOutputBuffer = noPreSilencedOutputBuffer
        self.noClip = noClip
        self.noDisableDenormals = noDisableDenormals
        self.noFixedSizedCallback = noFixedSizedCallback
        self.wasapiNoAutoConvertSrc = wasapiNoAutoConvertSrc
        self.wasapiNoDefaultQualitySrc = wasapiNoDefaultQualitySrc
        self.alsaNoMMap = alsaNoMMap
        self.alsaNoAutoFormat = alsaNoAutoFormat
        self.alsaNoAutoChannels = alsaNoAutoChannels
        self.alsaNoAutoResample = alsaNoAutoResample
    }
}

// parity: core/src/audio.ts#AudioSetupOptions [status=implemented hash=02d01ffce5ed]
public struct AudioSetupOptions: Sendable {
    public var autoStart: Bool?
    public var sampleRate: Int?
    public var playbackChannels: Int?
    public var startOptions: AudioStartOptions?
    public var outputSink: (any AudioOutputSink)?

    public init(
        autoStart: Bool? = nil,
        sampleRate: Int? = nil,
        playbackChannels: Int? = nil,
        startOptions: AudioStartOptions? = nil,
        outputSink: (any AudioOutputSink)? = nil
    ) {
        self.autoStart = autoStart
        self.sampleRate = sampleRate
        self.playbackChannels = playbackChannels
        self.startOptions = startOptions
        self.outputSink = outputSink
    }
}

// parity: core/src/audio.ts#AudioPlayOptions [status=implemented hash=cec694354d67]
public struct AudioPlayOptions: Equatable, Sendable {
    public var volume: Double?
    public var pan: Double?
    public var loop: Bool?
    public var groupId: AudioGroup?
    public var pitch: Double?
    public var fadeInSeconds: Double?

    public init(
        volume: Double? = nil,
        pan: Double? = nil,
        loop: Bool? = nil,
        groupId: AudioGroup? = nil,
        pitch: Double? = nil,
        fadeInSeconds: Double? = nil
    ) {
        self.volume = volume
        self.pan = pan
        self.loop = loop
        self.groupId = groupId
        self.pitch = pitch
        self.fadeInSeconds = fadeInSeconds
    }
}

// parity: core/src/audio.ts#AudioStreamBody [status=implemented hash=8504eaa96c25]
public enum AudioStreamBody: Sendable {
    case chunks([[UInt8]])
    case asyncStream(AsyncStream<[UInt8]>)
}

// parity: core/src/audio.ts#AudioStreamFormat [status=implemented hash=3a873bca089a]
public enum AudioStreamFormat: String, Equatable, Hashable, Sendable, CaseIterable {
    case mp3
    case flac
    case pcm
}

// parity: core/src/audio.ts#AudioStreamContentTypeContext [status=implemented hash=81db42543362]
public struct AudioStreamContentTypeContext: Equatable, Hashable, Sendable {
    public let format: AudioStreamFormat
    public let contentType: String?
    public let status: Int
    public let url: String

    public init(format: AudioStreamFormat, contentType: String?, status: Int, url: String) {
        self.format = format
        self.contentType = contentType
        self.status = status
        self.url = url
    }
}

// parity: core/src/audio.ts#AudioStreamContentTypePolicy [status=implemented hash=deb454480040]
public enum AudioStreamContentTypePolicy: Sendable {
    case validate
    case ignore
    case custom(@Sendable (AudioStreamContentTypeContext) -> Bool)
}

// parity: core/src/audio.ts#AudioStreamConnectContext [status=implemented hash=543a1cb51d7b]
public struct AudioStreamConnectContext: Equatable, Hashable, Sendable {
    public let attempt: Int

    public init(attempt: Int) {
        self.attempt = attempt
    }
}

// parity: core/src/audio.ts#AudioStreamConnection [status=implemented hash=e727dba16507]
public struct AudioStreamConnection<I: Sendable>: Sendable {
    public let body: AudioStreamBody
    public let info: I
    public let close: (@Sendable () async -> Void)?

    public init(body: AudioStreamBody, info: I, close: (@Sendable () async -> Void)? = nil) {
        self.body = body
        self.info = info
        self.close = close
    }
}

// parity: core/src/audio.ts#AudioStreamRetryPhase [status=implemented hash=a3c83be779e9]
public enum AudioStreamRetryPhase: String, Equatable, Hashable, Sendable {
    case connect
    case read
}

// parity: core/src/audio.ts#AudioStreamRetryContext [status=implemented hash=2c0158c715e4]
public struct AudioStreamRetryContext: Equatable, Hashable, Sendable {
    public let attempt: Int
    public let maxRetries: Int
    public let phase: AudioStreamRetryPhase

    public init(attempt: Int, maxRetries: Int, phase: AudioStreamRetryPhase) {
        self.attempt = attempt
        self.maxRetries = maxRetries
        self.phase = phase
    }
}

// parity: core/src/audio.ts#AudioStreamRetryDecision [status=implemented hash=f241a045c4e4]
public enum AudioStreamRetryDecision: Equatable, Hashable, Sendable {
    case stop
    case retry(delayMs: Int?)
}

// parity: core/src/audio.ts#AudioStreamConnector [status=implemented hash=a7cedfcdda11]
public protocol AudioStreamConnector<Info>: Sendable {
    associatedtype Info: Sendable
    func connect(context: AudioStreamConnectContext) async throws -> AudioStreamConnection<Info>
}

// parity: core/src/audio.ts#AudioStreamBufferOptions [status=implemented hash=e0ef83dd922f]
public struct AudioStreamBufferOptions: Equatable, Hashable, Sendable {
    public var capacityMs: Int?
    public var startupMs: Int?
    public var resumeMs: Int?

    public init(capacityMs: Int? = nil, startupMs: Int? = nil, resumeMs: Int? = nil) {
        self.capacityMs = capacityMs
        self.startupMs = startupMs
        self.resumeMs = resumeMs
    }
}

// parity: core/src/audio.ts#AudioStreamReconnectOptions [status=implemented hash=07382d4125cb]
public struct AudioStreamReconnectOptions: Sendable {
    public var maxRetries: Int?
    public var initialDelayMs: Int?
    public var maxDelayMs: Int?
    public var backoffFactor: Double?
    public var retryOnEnd: Bool?
    public var retry: (@Sendable (AudioStreamError, AudioStreamRetryContext) -> AudioStreamRetryDecision)?

    public init(
        maxRetries: Int? = nil,
        initialDelayMs: Int? = nil,
        maxDelayMs: Int? = nil,
        backoffFactor: Double? = nil,
        retryOnEnd: Bool? = nil,
        retry: (@Sendable (AudioStreamError, AudioStreamRetryContext) -> AudioStreamRetryDecision)? = nil
    ) {
        self.maxRetries = maxRetries
        self.initialDelayMs = initialDelayMs
        self.maxDelayMs = maxDelayMs
        self.backoffFactor = backoffFactor
        self.retryOnEnd = retryOnEnd
        self.retry = retry
    }
}

// parity: core/src/audio.ts#AudioStreamOptions [status=implemented hash=74f34b007ffc]
public struct AudioStreamOptions: Sendable {
    public var format: AudioStreamFormat?
    public var sampleFormat: AudioSampleFormat?
    public var sampleRate: Int?
    public var channels: Int?
    public var volume: Double?
    public var pan: Double?
    public var groupId: AudioGroup?
    public var maxProbeBytes: Int?
    public var buffer: AudioStreamBufferOptions?

    public init(
        format: AudioStreamFormat? = nil,
        sampleFormat: AudioSampleFormat? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        volume: Double? = nil,
        pan: Double? = nil,
        groupId: AudioGroup? = nil,
        maxProbeBytes: Int? = nil,
        buffer: AudioStreamBufferOptions? = nil
    ) {
        self.format = format
        self.sampleFormat = sampleFormat
        self.sampleRate = sampleRate
        self.channels = channels
        self.volume = volume
        self.pan = pan
        self.groupId = groupId
        self.maxProbeBytes = maxProbeBytes
        self.buffer = buffer
    }
}

// parity: core/src/audio.ts#AudioStreamBodyOptions [status=implemented hash=164fea9061f1]
public struct AudioStreamBodyOptions<M: Sendable>: Sendable {
    public var stream: AudioStreamOptions
    public var demuxer: AudioStreamDemuxerFactory<M>?

    public init(stream: AudioStreamOptions = AudioStreamOptions(), demuxer: AudioStreamDemuxerFactory<M>? = nil) {
        self.stream = stream
        self.demuxer = demuxer
    }
}

// parity: core/src/audio.ts#AudioStreamSourceOptions [status=implemented hash=b6546b736e14]
public struct AudioStreamSourceOptions<I: Sendable, M: Sendable>: Sendable {
    public var stream: AudioStreamOptions
    public var demuxer: (@Sendable (I) throws -> (any AudioStreamDemuxer<M>)?)?
    public var reconnect: AudioStreamReconnectOptions?

    public init(
        stream: AudioStreamOptions = AudioStreamOptions(),
        demuxer: (@Sendable (I) throws -> (any AudioStreamDemuxer<M>)?)? = nil,
        reconnect: AudioStreamReconnectOptions? = nil
    ) {
        self.stream = stream
        self.demuxer = demuxer
        self.reconnect = reconnect
    }
}

/// Injectable HTTP response payload for pure-Swift URL streaming without OS networking imports.
public struct AudioStreamUrlResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: AudioStreamBody
    public let url: String

    public init(status: Int = 200, headers: [String: String] = [:], body: AudioStreamBody, url: String = "") {
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url
    }
}

// parity: core/src/audio.ts#AudioStreamUrlOptions [status=implemented hash=4fd3c4997682]
public struct AudioStreamUrlOptions: Sendable {
    public var stream: AudioStreamOptions
    public var reconnect: AudioStreamReconnectOptions?
    public var metadataEncoding: String?
    public var contentTypePolicy: AudioStreamContentTypePolicy?
    public var headers: [String: String]?
    public var fetcher: (@Sendable (String, [String: String]) async throws -> AudioStreamUrlResponse)?

    public init(
        stream: AudioStreamOptions = AudioStreamOptions(),
        reconnect: AudioStreamReconnectOptions? = nil,
        metadataEncoding: String? = nil,
        contentTypePolicy: AudioStreamContentTypePolicy? = nil,
        headers: [String: String]? = nil,
        fetcher: (@Sendable (String, [String: String]) async throws -> AudioStreamUrlResponse)? = nil
    ) {
        self.stream = stream
        self.reconnect = reconnect
        self.metadataEncoding = metadataEncoding
        self.contentTypePolicy = contentTypePolicy
        self.headers = headers
        self.fetcher = fetcher
    }
}

// parity: core/src/audio.ts#AudioStreamState [status=implemented hash=1a1bf9e36546]
public enum AudioStreamState: String, Equatable, Hashable, Sendable, CaseIterable {
    case initializing
    case buffering
    case playing
    case reconnecting
    case ended
    case errored
    case disposed
}

// parity: core/src/audio.ts#AudioStreamStats [status=implemented hash=b2431edda580]
public struct AudioStreamStats: Equatable, Sendable {
    public var state: AudioStreamState
    public var sampleRate: Int
    public var channels: Int
    public var bufferedFrames: Int
    public var capacityFrames: Int
    public var bufferedDurationMs: Double
    public var bytesReceived: UInt64
    public var framesDecoded: UInt64
    public var framesPlayed: UInt64
    public var underruns: Int
    public var reconnectAttempts: Int

    public init(
        state: AudioStreamState = .initializing,
        sampleRate: Int = 0,
        channels: Int = 0,
        bufferedFrames: Int = 0,
        capacityFrames: Int = 0,
        bufferedDurationMs: Double = 0,
        bytesReceived: UInt64 = 0,
        framesDecoded: UInt64 = 0,
        framesPlayed: UInt64 = 0,
        underruns: Int = 0,
        reconnectAttempts: Int = 0
    ) {
        self.state = state
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferedFrames = bufferedFrames
        self.capacityFrames = capacityFrames
        self.bufferedDurationMs = bufferedDurationMs
        self.bytesReceived = bytesReceived
        self.framesDecoded = framesDecoded
        self.framesPlayed = framesPlayed
        self.underruns = underruns
        self.reconnectAttempts = reconnectAttempts
    }
}

// parity: core/src/audio.ts#AudioStreamMetadataFormat [status=implemented hash=05903742980d]
public enum AudioStreamMetadataFormat: String, Equatable, Hashable, Sendable, Codable {
    case icy
}

// parity: core/src/audio.ts#AudioStreamMetadata [status=implemented hash=6c64a2d0306a]
public struct AudioStreamMetadata: Equatable, Hashable, Sendable, Codable {
    public let format: AudioStreamMetadataFormat
    public let headers: [String: String]
    public let fields: [String: String]

    public init(format: AudioStreamMetadataFormat, headers: [String: String], fields: [String: String]) {
        self.format = format
        self.headers = headers
        self.fields = fields
    }

    public var streamTitle: String? { fields["StreamTitle"] }
    public var streamUrl: String? { fields["StreamUrl"] }
}

// parity: core/src/audio.ts#AudioStreamAction [status=implemented hash=b9f1b0f91163]
public enum AudioStreamAction: String, Equatable, Hashable, Sendable {
    case fetch
    case response
    case source
    case demuxer
    case create
    case write
    case end
    case restart
    case stats
    case decoder
    case destroy
    case setVolume
    case setPan
    case setGroup
}

// parity: core/src/audio.ts#AudioStreamErrorContext [status=implemented hash=8b7f68fce14e]
public struct AudioStreamErrorContext: Equatable, Hashable, Sendable {
    public var action: AudioStreamAction
    public var status: Int?
    public var errorCode: Int?
    public var attempt: Int?

    public init(action: AudioStreamAction, status: Int? = nil, errorCode: Int? = nil, attempt: Int? = nil) {
        self.action = action
        self.status = status
        self.errorCode = errorCode
        self.attempt = attempt
    }
}

// parity: core/src/audio.ts#AudioStreamReconnectEvent [status=implemented hash=7a4818c07578]
public struct AudioStreamReconnectEvent: Sendable {
    public let attempt: Int
    public let delayMs: Int
    public let maxRetries: Int
    public let error: AudioStreamError

    public init(attempt: Int, delayMs: Int, maxRetries: Int, error: AudioStreamError) {
        self.attempt = attempt
        self.delayMs = delayMs
        self.maxRetries = maxRetries
        self.error = error
    }
}

// parity: core/src/audio.ts#AudioStreamEvents [status=implemented hash=2e833aa478d2]
public struct AudioStreamEvents<M: Sendable>: Sendable {
    public var onMetadata: (@Sendable (M?) -> Void)?
    public var onReconnecting: (@Sendable (AudioStreamReconnectEvent) -> Void)?
    public var onEnded: (@Sendable () -> Void)?
    public var onError: (@Sendable (any Error, AudioStreamErrorContext) -> Void)?
    public var onDisposed: (@Sendable () -> Void)?

    public init(
        onMetadata: (@Sendable (M?) -> Void)? = nil,
        onReconnecting: (@Sendable (AudioStreamReconnectEvent) -> Void)? = nil,
        onEnded: (@Sendable () -> Void)? = nil,
        onError: (@Sendable (any Error, AudioStreamErrorContext) -> Void)? = nil,
        onDisposed: (@Sendable () -> Void)? = nil
    ) {
        self.onMetadata = onMetadata
        self.onReconnecting = onReconnecting
        self.onEnded = onEnded
        self.onError = onError
        self.onDisposed = onDisposed
    }
}

// parity: core/src/audio.ts#AudioPlaybackDevice [status=implemented hash=dd5358b4a743]
public struct AudioPlaybackDevice: Equatable, Hashable, Sendable, Codable {
    public var index: Int
    public var name: String
    public var isDefault: Bool

    public init(index: Int, name: String, isDefault: Bool) {
        self.index = index
        self.name = name
        self.isDefault = isDefault
    }
}

// parity: core/src/audio.ts#AudioCaptureDevice [status=implemented hash=adac87dd7e21]
public struct AudioCaptureDevice: Equatable, Hashable, Sendable, Codable {
    public var index: Int
    public var name: String
    public var isDefault: Bool

    public init(index: Int, name: String, isDefault: Bool) {
        self.index = index
        self.name = name
        self.isDefault = isDefault
    }
}

// parity: core/src/audio.ts#AudioCaptureOptions [status=implemented hash=8ab295f9622f]
public struct AudioCaptureOptions: Equatable, Hashable, Sendable {
    public var channels: Int?
    public var capacityFrames: Int?
    public var startOptions: AudioStartOptions?

    public init(channels: Int? = nil, capacityFrames: Int? = nil, startOptions: AudioStartOptions? = nil) {
        self.channels = channels
        self.capacityFrames = capacityFrames
        self.startOptions = startOptions
    }
}

// parity: core/src/audio.ts#AudioCaptureStreamOptions [status=implemented hash=b69b87d62456]
public struct AudioCaptureStreamOptions: Equatable, Hashable, Sendable {
    public var channels: Int?
    public var capacityFrames: Int?
    public var chunkFrames: Int?
    public var startOptions: AudioStartOptions?

    public init(
        channels: Int? = nil,
        capacityFrames: Int? = nil,
        chunkFrames: Int? = nil,
        startOptions: AudioStartOptions? = nil
    ) {
        self.channels = channels
        self.capacityFrames = capacityFrames
        self.chunkFrames = chunkFrames
        self.startOptions = startOptions
    }
}

// parity: core/src/audio.ts#AudioCaptureStreamState [status=implemented hash=997dd3455e73]
public enum AudioCaptureStreamState: String, Equatable, Hashable, Sendable, CaseIterable {
    case initializing
    case capturing
    case stopping
    case stopped
    case errored
    case disposed
}

// parity: core/src/audio.ts#AudioCaptureStreamAction [status=implemented hash=2d959a519303]
public enum AudioCaptureStreamAction: String, Equatable, Hashable, Sendable {
    case start
    case read
    case stop
    case stats
    case destroy
}

// parity: core/src/audio.ts#AudioCaptureStreamErrorContext [status=implemented hash=f7000e985231]
public struct AudioCaptureStreamErrorContext: Equatable, Hashable, Sendable {
    public var action: AudioCaptureStreamAction
    public var status: Int?

    public init(action: AudioCaptureStreamAction, status: Int? = nil) {
        self.action = action
        self.status = status
    }
}

// parity: core/src/audio.ts#AudioCaptureStreamEvents [status=implemented hash=2445070de7cb]
public struct AudioCaptureStreamEvents: Sendable {
    public var onStopped: (@Sendable () -> Void)?
    public var onError: (@Sendable (AudioCaptureStreamError, AudioCaptureStreamErrorContext) -> Void)?
    public var onDisposed: (@Sendable () -> Void)?

    public init(
        onStopped: (@Sendable () -> Void)? = nil,
        onError: (@Sendable (AudioCaptureStreamError, AudioCaptureStreamErrorContext) -> Void)? = nil,
        onDisposed: (@Sendable () -> Void)? = nil
    ) {
        self.onStopped = onStopped
        self.onError = onError
        self.onDisposed = onDisposed
    }
}

// parity: core/src/audio.ts#AudioCaptureStats [status=implemented hash=50d0544c1fb0]
public struct AudioCaptureStats: Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var capacityFrames: Int
    public var bufferedFrames: Int
    public var framesReceived: UInt64
    public var framesRead: UInt64
    public var framesDropped: UInt64

    public init(
        sampleRate: Int = 48_000,
        channels: Int = 1,
        capacityFrames: Int = 48_000,
        bufferedFrames: Int = 0,
        framesReceived: UInt64 = 0,
        framesRead: UInt64 = 0,
        framesDropped: UInt64 = 0
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.capacityFrames = capacityFrames
        self.bufferedFrames = bufferedFrames
        self.framesReceived = framesReceived
        self.framesRead = framesRead
        self.framesDropped = framesDropped
    }
}

// parity: core/src/audio.ts#AudioCaptureStreamStats [status=implemented hash=c09e19f972c8]
public struct AudioCaptureStreamStats: Equatable, Sendable {
    public var capture: AudioCaptureStats
    public var state: AudioCaptureStreamState
    public var bufferedDurationMs: Double

    public var sampleRate: Int { capture.sampleRate }
    public var channels: Int { capture.channels }
    public var capacityFrames: Int { capture.capacityFrames }
    public var bufferedFrames: Int { capture.bufferedFrames }
    public var framesReceived: UInt64 { capture.framesReceived }
    public var framesRead: UInt64 { capture.framesRead }
    public var framesDropped: UInt64 { capture.framesDropped }

    public init(capture: AudioCaptureStats, state: AudioCaptureStreamState) {
        self.capture = capture
        self.state = state
        self.bufferedDurationMs = capture.sampleRate == 0
            ? 0
            : (Double(capture.bufferedFrames) * 1000.0) / Double(capture.sampleRate)
    }
}

// parity: core/src/audio.ts#AudioCaptureReadResult [status=implemented hash=6a3fe523ad45]
public struct AudioCaptureReadResult: Equatable, Sendable {
    public let frames: [Float]
    public let framesRead: Int

    public init(frames: [Float], framesRead: Int) {
        self.frames = frames
        self.framesRead = framesRead
    }
}

// parity: core/src/audio.ts#AudioRecordToFileOptions [status=implemented hash=1c475f71e8d3]
public typealias AudioRecordToFileOptions = AudioCaptureStreamOptions

// parity: core/src/audio.ts#AudioRecorderState [status=implemented hash=edb16c94c3ab]
public enum AudioRecorderState: String, Equatable, Hashable, Sendable, CaseIterable {
    case initializing
    case recording
    case stopping
    case stopped
    case errored
    case disposed
}

// parity: core/src/audio.ts#AudioRecorderAction [status=implemented hash=95966183fadf]
public enum AudioRecorderAction: String, Equatable, Hashable, Sendable {
    case open
    case start
    case read
    case write
    case stop
    case finalize
    case publish
    case stats
    case destroy
}

// parity: core/src/audio.ts#AudioRecorderErrorContext [status=implemented hash=da0708368a32]
public struct AudioRecorderErrorContext: Equatable, Hashable, Sendable {
    public var action: AudioRecorderAction
    public var status: Int?

    public init(action: AudioRecorderAction, status: Int? = nil) {
        self.action = action
        self.status = status
    }
}

// parity: core/src/audio.ts#AudioRecorderEvents [status=implemented hash=05fb32bd0955]
public struct AudioRecorderEvents: Sendable {
    public var onStopped: (@Sendable () -> Void)?
    public var onError: (@Sendable (AudioRecorderError, AudioRecorderErrorContext) -> Void)?
    public var onDisposed: (@Sendable () -> Void)?

    public init(
        onStopped: (@Sendable () -> Void)? = nil,
        onError: (@Sendable (AudioRecorderError, AudioRecorderErrorContext) -> Void)? = nil,
        onDisposed: (@Sendable () -> Void)? = nil
    ) {
        self.onStopped = onStopped
        self.onError = onError
        self.onDisposed = onDisposed
    }
}

// parity: core/src/audio.ts#AudioRecorderStats [status=implemented hash=afb09478c93d]
public struct AudioRecorderStats: Equatable, Sendable {
    public var capture: AudioCaptureStats
    public var state: AudioRecorderState
    public var bufferedDurationMs: Double
    public var framesWritten: UInt64
    public var dataBytesWritten: UInt64
    public var durationMs: Double

    public init(
        capture: AudioCaptureStats,
        state: AudioRecorderState,
        framesWritten: UInt64,
        dataBytesWritten: UInt64
    ) {
        self.capture = capture
        self.state = state
        self.bufferedDurationMs = capture.sampleRate == 0
            ? 0
            : (Double(capture.bufferedFrames) * 1000.0) / Double(capture.sampleRate)
        self.framesWritten = framesWritten
        self.dataBytesWritten = dataBytesWritten
        self.durationMs = capture.sampleRate == 0
            ? 0
            : (Double(framesWritten) * 1000.0) / Double(capture.sampleRate)
    }
}

// parity: core/src/audio.ts#AudioAction [status=implemented hash=871e54fc2732]
public enum AudioAction: String, Equatable, Hashable, Sendable {
    case createAudioEngine
    case start
    case startMixer
    case stop
    case loadSound
    case loadSoundFile
    case unloadSound
    case group
    case play
    case stopVoice
    case setVoiceGroup
    case setGroupVolume
    case setMasterVolume
    case mixFrames
    case enableTap
    case readTapFrames
    case listPlaybackDevices
    case selectPlaybackDevice
    case clearPlaybackDeviceSelection
    case listCaptureDevices
    case selectCaptureDevice
    case clearCaptureDeviceSelection
    case startCapture
    case readCaptureFrames
    case getCaptureStats
    case stopCapture
    case getStats
}

// parity: core/src/audio.ts#AudioErrorContext [status=implemented hash=70891f94a8a7]
public struct AudioErrorContext: Equatable, Hashable, Sendable {
    public var action: AudioAction
    public var status: Int?

    public init(action: AudioAction, status: Int? = nil) {
        self.action = action
        self.status = status
    }
}

// parity: core/src/audio.ts#AudioEvents [status=implemented hash=f6c4ed5836bd]
public struct AudioEvents: Sendable {
    public var onError: (@Sendable (any Error, AudioErrorContext) -> Void)?
    public var onStarted: (@Sendable () -> Void)?
    public var onMixerStarted: (@Sendable () -> Void)?
    public var onCaptureStarted: (@Sendable () -> Void)?
    public var onCaptureStopped: (@Sendable () -> Void)?
    public var onStopped: (@Sendable () -> Void)?
    public var onDisposed: (@Sendable () -> Void)?

    public init(
        onError: (@Sendable (any Error, AudioErrorContext) -> Void)? = nil,
        onStarted: (@Sendable () -> Void)? = nil,
        onMixerStarted: (@Sendable () -> Void)? = nil,
        onCaptureStarted: (@Sendable () -> Void)? = nil,
        onCaptureStopped: (@Sendable () -> Void)? = nil,
        onStopped: (@Sendable () -> Void)? = nil,
        onDisposed: (@Sendable () -> Void)? = nil
    ) {
        self.onError = onError
        self.onStarted = onStarted
        self.onMixerStarted = onMixerStarted
        self.onCaptureStarted = onCaptureStarted
        self.onCaptureStopped = onCaptureStopped
        self.onStopped = onStopped
        self.onDisposed = onDisposed
    }
}

// parity: core/src/audio.ts#AudioInitializationAction [status=implemented hash=f1521f880faa]
public enum AudioInitializationAction: String, Equatable, Hashable, Sendable {
    case resolveRenderLib
    case createAudioEngine
    case start
}

/// Mixer engine telemetry snapshot matching `core/src/zig-structs.ts#AudioStats`.
public struct AudioStats: Equatable, Sendable {
    public var soundsLoaded: Int
    public var voicesActive: Int
    public var framesMixed: UInt64
    public var lockMisses: Int
    public var lastPeak: Float
    public var lastRms: Float

    public init(
        soundsLoaded: Int = 0,
        voicesActive: Int = 0,
        framesMixed: UInt64 = 0,
        lockMisses: Int = 0,
        lastPeak: Float = 0,
        lastRms: Float = 0
    ) {
        self.soundsLoaded = soundsLoaded
        self.voicesActive = voicesActive
        self.framesMixed = framesMixed
        self.lockMisses = lockMisses
        self.lastPeak = lastPeak
        self.lastRms = lastRms
    }
}

// MARK: - Error Classes

// parity: core/src/audio.ts#AudioInitializationError [status=implemented hash=7a9d40a0c75a]
public final class AudioInitializationError: Error, Sendable, CustomStringConvertible {
    public let action: AudioInitializationAction
    public let message: String
    public let status: Int?

    public init(action: AudioInitializationAction, message: String, status: Int? = nil) {
        self.action = action
        self.message = message
        self.status = status
    }

    public var description: String { message }
}

// parity: core/src/audio.ts#AudioCaptureStreamError [status=implemented hash=cf20c769c002]
public final class AudioCaptureStreamError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let context: AudioCaptureStreamErrorContext

    public init(message: String, context: AudioCaptureStreamErrorContext) {
        self.message = message
        self.context = context
    }

    public var description: String { message }
}

// parity: core/src/audio.ts#AudioRecorderError [status=implemented hash=98b4d0d3a8b0]
public final class AudioRecorderError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let context: AudioRecorderErrorContext

    public init(message: String, context: AudioRecorderErrorContext) {
        self.message = message
        self.context = context
    }

    public var description: String { message }
}

// parity: core/src/audio.ts#AudioStreamError [status=implemented hash=ebde1171ecc1]
public final class AudioStreamError: Error, Sendable, CustomStringConvertible {
    public let message: String
    public let context: AudioStreamErrorContext

    public init(message: String, context: AudioStreamErrorContext) {
        self.message = message
        self.context = context
    }

    public var description: String { message }
}

// MARK: - Internal Ring Buffer & Voice Graph

private struct FloatRingBuffer: Sendable {
    private var storage: [Float]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var countSamples: Int = 0
    let channels: Int
    let capacityFrames: Int

    init(capacityFrames: Int, channels: Int) {
        self.channels = max(1, channels)
        self.capacityFrames = max(1, capacityFrames)
        self.storage = Array(repeating: 0, count: self.capacityFrames * self.channels)
    }

    var bufferedFrames: Int {
        countSamples / channels
    }

    mutating func write(_ samples: [Float]) -> (writtenFrames: Int, droppedFrames: Int) {
        let incomingFrames = samples.count / channels
        guard incomingFrames > 0 else { return (0, 0) }
        var written = 0
        var dropped = 0
        let capSamples = storage.count

        for f in 0..<incomingFrames {
            if countSamples + channels > capSamples {
                // Drop oldest frame on overflow
                readIndex = (readIndex + channels) % capSamples
                countSamples -= channels
                dropped += 1
            }
            for ch in 0..<channels {
                storage[writeIndex] = samples[f * channels + ch]
                writeIndex = (writeIndex + 1) % capSamples
            }
            countSamples += channels
            written += 1
        }
        return (written, dropped)
    }

    mutating func read(maxFrames: Int) -> (frames: [Float], framesRead: Int) {
        let toRead = min(max(0, maxFrames), bufferedFrames)
        let sampleCount = toRead * channels
        var out: [Float] = []
        out.reserveCapacity(sampleCount)
        let capSamples = storage.count

        for _ in 0..<sampleCount {
            out.append(storage[readIndex])
            readIndex = (readIndex + 1) % capSamples
        }
        countSamples -= sampleCount
        return (out, toRead)
    }

    mutating func clear() {
        readIndex = 0
        writeIndex = 0
        countSamples = 0
    }
}

private struct FadeRamp: Sendable {
    var startVolume: Double
    var targetVolume: Double
    var totalFrames: Int
    var elapsedFrames: Int
    var stopWhenComplete: Bool
}

private struct MixerVoice: Sendable {
    let id: AudioVoice
    let soundId: AudioSound
    var volume: Double
    var pan: Double
    var pitch: Double
    var loop: Bool
    var groupId: AudioGroup
    var framePosition: Double
    var isPaused: Bool
    var fade: FadeRamp?
}

// MARK: - AudioStream

/// Streaming audio playback handle supporting PCM f32le ingestion, ICY metadata demuxing,
/// live gain/pan/group controls, stats reporting, and lifecycle disposal.
// parity: core/src/audio.ts#AudioStream [status=implemented hash=7823e0cef91a]
public final class AudioStream<M: Sendable>: @unchecked Sendable {
    public let format: AudioStreamFormat
    public var events: AudioStreamEvents<M> = AudioStreamEvents()

    private weak var owner: Audio?
    private let streamId: UInt32
    private var currentState: AudioStreamState = .initializing
    private var metadata: M? = nil
    private var statsValue: AudioStreamStats
    private var pcmRing: FloatRingBuffer
    private var volume: Double
    private var pan: Double
    private var groupId: AudioGroup
    private var disposed: Bool = false
    private let removeFromOwner: () -> Void

    internal init(
        owner: Audio,
        streamId: UInt32,
        format: AudioStreamFormat,
        sampleRate: Int,
        channels: Int,
        capacityFrames: Int,
        volume: Double,
        pan: Double,
        groupId: AudioGroup,
        removeFromOwner: @escaping () -> Void
    ) {
        self.owner = owner
        self.streamId = streamId
        self.format = format
        self.volume = volume
        self.pan = pan
        self.groupId = groupId
        self.pcmRing = FloatRingBuffer(capacityFrames: max(1, capacityFrames), channels: max(1, channels))
        self.statsValue = AudioStreamStats(
            state: .initializing,
            sampleRate: sampleRate,
            channels: channels,
            bufferedFrames: 0,
            capacityFrames: capacityFrames,
            bufferedDurationMs: 0
        )
        self.removeFromOwner = removeFromOwner
    }

    // parity: core/src/audio.ts#AudioStream.state [status=implemented hash=a6b2b21f3189]
    public var state: AudioStreamState {
        disposed ? .disposed : currentState
    }

    // parity: core/src/audio.ts#AudioStream.getStats [status=implemented hash=5233769722a4]
    public func getStats() -> AudioStreamStats {
        statsValue.state = state
        statsValue.bufferedFrames = pcmRing.bufferedFrames
        statsValue.bufferedDurationMs = statsValue.sampleRate == 0
            ? 0
            : (Double(statsValue.bufferedFrames) * 1000.0) / Double(statsValue.sampleRate)
        return statsValue
    }

    // parity: core/src/audio.ts#AudioStream.getMetadata [status=implemented hash=f35c8401696c]
    public func getMetadata() -> M? {
        metadata
    }

    // parity: core/src/audio.ts#AudioStream.setVolume [status=implemented hash=1a57b83128db]
    @discardableResult
    public func setVolume(_ volume: Double) -> Bool {
        guard !disposed, volume.isFinite, volume >= 0 else { return false }
        self.volume = volume
        return true
    }

    // parity: core/src/audio.ts#AudioStream.setPan [status=implemented hash=4ee7596ab2cb]
    @discardableResult
    public func setPan(_ pan: Double) -> Bool {
        guard !disposed, pan.isFinite else { return false }
        self.pan = max(-1.0, min(1.0, pan))
        return true
    }

    // parity: core/src/audio.ts#AudioStream.setGroup [status=implemented hash=807dadd54e41]
    @discardableResult
    public func setGroup(_ groupId: AudioGroup) -> Bool {
        guard !disposed else { return false }
        self.groupId = groupId
        return true
    }

    /// Pushes raw encoded/PCM bytes into the stream (used internally and for direct manual feeding).
    public func writeBytes(_ bytes: [UInt8]) {
        guard !disposed, !bytes.isEmpty else { return }
        statsValue.bytesReceived &+= UInt64(bytes.count)
        if format == .pcm {
            let decoded = PCMConverter.bytesLEToFloat32(bytes)
            let (written, _) = pcmRing.write(decoded)
            statsValue.framesDecoded &+= UInt64(written)
            if currentState == .initializing || currentState == .buffering {
                currentState = .playing
            }
        } else if currentState == .initializing {
            currentState = .buffering
        }
    }

    /// Reads buffered PCM frames from the stream (for mixing into the engine).
    public func readDecodedFrames(maxFrames: Int) -> [Float] {
        guard !disposed else { return [] }
        let (frames, readCount) = pcmRing.read(maxFrames: maxFrames)
        statsValue.framesPlayed &+= UInt64(readCount)
        if readCount < maxFrames && currentState == .playing {
            statsValue.underruns += 1
        }
        return frames
    }

    internal func updateMetadata(_ value: M?) {
        guard !disposed else { return }
        self.metadata = value
        events.onMetadata?(value)
    }

    internal func markEnded() {
        guard !disposed else { return }
        currentState = .ended
        events.onEnded?()
    }

    internal func markErrored(_ error: any Error, context: AudioStreamErrorContext) {
        guard !disposed else { return }
        currentState = .errored
        events.onError?(error, context)
    }

    internal var currentVolume: Double { volume }
    internal var currentPan: Double { pan }
    internal var currentGroupId: AudioGroup { groupId }

    // parity: core/src/audio.ts#AudioStream.dispose [status=implemented hash=beac14f20a85]
    public func dispose() {
        guard !disposed else { return }
        disposed = true
        currentState = .disposed
        pcmRing.clear()
        removeFromOwner()
        events.onDisposed?()
    }
}

// MARK: - AudioCaptureStream

/// Capture ring stream handle exposing deterministic chunk reads, stats, and lifecycle control.
// parity: core/src/audio.ts#AudioCaptureStream [status=implemented hash=45bac83195b1]
public final class AudioCaptureStream: @unchecked Sendable {
    public let sampleRate: Int
    public let channels: Int
    public let chunkFrames: Int
    public var events: AudioCaptureStreamEvents = AudioCaptureStreamEvents()

    private weak var owner: Audio?
    private var currentState: AudioCaptureStreamState = .initializing
    private var latestStats: AudioCaptureStats
    private let removeFromOwner: () -> Void

    internal init(
        owner: Audio,
        sampleRate: Int,
        channels: Int,
        capacityFrames: Int,
        chunkFrames: Int,
        removeFromOwner: @escaping () -> Void
    ) {
        self.owner = owner
        self.sampleRate = sampleRate
        self.channels = channels
        self.chunkFrames = chunkFrames
        self.latestStats = AudioCaptureStats(
            sampleRate: sampleRate,
            channels: channels,
            capacityFrames: capacityFrames
        )
        self.removeFromOwner = removeFromOwner
        self.currentState = .capturing
    }

    // parity: core/src/audio.ts#AudioCaptureStream.state [status=implemented hash=594f3f304230]
    public var state: AudioCaptureStreamState {
        currentState
    }

    // parity: core/src/audio.ts#AudioCaptureStream.getStats [status=implemented hash=8f4c0e68fcf7]
    public func getStats() -> AudioCaptureStreamStats {
        if let owner, currentState != .disposed && currentState != .stopped {
            if let live = owner.internalCaptureStats() {
                latestStats = live
            }
        }
        return AudioCaptureStreamStats(capture: latestStats, state: currentState)
    }

    /// Reads up to `frameCount` (defaults to `chunkFrames`) interleaved float32 frames from capture.
    public func readChunk(frameCount: Int? = nil) -> AudioCaptureReadResult {
        guard currentState == .capturing || currentState == .stopping, let owner else {
            return AudioCaptureReadResult(frames: [], framesRead: 0)
        }
        let requested = max(1, frameCount ?? chunkFrames)
        let result = owner.internalReadCapture(frameCount: requested)
        if let live = owner.internalCaptureStats() {
            latestStats = live
        }
        return result
    }

    // parity: core/src/audio.ts#AudioCaptureStream.stop [status=implemented hash=7b576eae0b34]
    public func stop() {
        guard currentState == .capturing || currentState == .initializing else { return }
        currentState = .stopping
        _ = owner?.internalStopCapture()
        if let live = owner?.internalCaptureStats() {
            latestStats = live
        }
        currentState = .stopped
        removeFromOwner()
        events.onStopped?()
    }

    // parity: core/src/audio.ts#AudioCaptureStream.dispose [status=implemented hash=21e9dd2a633a]
    public func dispose() {
        guard currentState != .disposed else { return }
        if currentState == .capturing || currentState == .stopping {
            _ = owner?.internalStopCapture()
        }
        if let live = owner?.internalCaptureStats() {
            latestStats = live
        }
        currentState = .disposed
        removeFromOwner()
        events.onDisposed?()
    }
}

// MARK: - AudioRecorder

/// Pure-Swift WAV audio recorder consuming captured PCM frames into an encoded RIFF WAVE byte buffer
/// (and optional custom publish sink, keeping `OpenTUICore` free of OS filesystem imports).
// parity: core/src/audio.ts#AudioRecorder [status=implemented hash=7ba6ab6a74ca]
public final class AudioRecorder: @unchecked Sendable {
    public let filePath: String
    public let format: String = "wav"
    public let sampleRate: Int
    public let channels: Int
    public var events: AudioRecorderEvents = AudioRecorderEvents()

    private let capture: AudioCaptureStream
    private var currentState: AudioRecorderState = .initializing
    private var pcmPayloadBytes: [UInt8] = []
    private var framesWritten: UInt64 = 0
    private var dataBytesWritten: UInt64 = 0
    private var finalizedWavBytes: [UInt8]? = nil
    private let onPublish: (@Sendable (String, [UInt8]) -> Void)?
    private let removeFromOwner: () -> Void

    internal init(
        filePath: String,
        capture: AudioCaptureStream,
        onPublish: (@Sendable (String, [UInt8]) -> Void)? = nil,
        removeFromOwner: @escaping () -> Void
    ) {
        self.filePath = filePath
        self.sampleRate = capture.sampleRate
        self.channels = capture.channels
        self.capture = capture
        self.onPublish = onPublish
        self.removeFromOwner = removeFromOwner
        self.currentState = .recording
    }

    // parity: core/src/audio.ts#AudioRecorder.state [status=implemented hash=6150b3b3e6b4]
    public var state: AudioRecorderState {
        currentState
    }

    /// Drains currently available captured frames and encodes them as 16-bit LE PCM samples.
    @discardableResult
    public func drainCapture() -> Int {
        guard currentState == .recording || currentState == .stopping else { return 0 }
        var totalFrames = 0
        while true {
            let chunk = capture.readChunk()
            guard chunk.framesRead > 0 else { break }
            let bytes = PCMConverter.float32ToInt16BytesLE(chunk.frames)
            pcmPayloadBytes.append(contentsOf: bytes)
            dataBytesWritten &+= UInt64(bytes.count)
            framesWritten &+= UInt64(chunk.framesRead)
            totalFrames += chunk.framesRead
        }
        return totalFrames
    }

    /// Returns the finalized RIFF WAVE bytes once `stop()` completes.
    public var recordedWavData: [UInt8]? {
        finalizedWavBytes
    }

    // parity: core/src/audio.ts#AudioRecorder.getStats [status=implemented hash=f8168d8f3374]
    public func getStats() -> AudioRecorderStats {
        let capStats = capture.getStats().capture
        return AudioRecorderStats(
            capture: capStats,
            state: currentState,
            framesWritten: framesWritten,
            dataBytesWritten: dataBytesWritten
        )
    }

    // parity: core/src/audio.ts#AudioRecorder.stop [status=implemented hash=fd8bbff2f1c0]
    public func stop() {
        guard currentState == .recording else { return }
        currentState = .stopping
        _ = drainCapture()
        capture.stop()
        var wav = WAVCodec.createHeader(
            sampleRate: sampleRate,
            channels: channels,
            dataBytes: pcmPayloadBytes.count,
            bitsPerSample: 16,
            isFloat: false
        )
        wav.append(contentsOf: pcmPayloadBytes)
        finalizedWavBytes = wav
        onPublish?(filePath, wav)
        currentState = .stopped
        removeFromOwner()
        events.onStopped?()
    }

    // parity: core/src/audio.ts#AudioRecorder.dispose [status=implemented hash=c98aff63bc21]
    public func dispose() {
        guard currentState != .disposed else { return }
        capture.dispose()
        pcmPayloadBytes.removeAll()
        currentState = .disposed
        removeFromOwner()
        events.onDisposed?()
    }
}

// MARK: - Audio Engine

/// Convenience alias for `Audio`.
public typealias AudioEngine = Audio

/// Pure-Swift cross-platform PCM audio engine, voice/group mixer, synthesizer host,
/// tap monitor, capture ring buffer, and streaming playback controller.
// parity: core/src/audio.ts#Audio [status=implemented hash=26854a427a4f]
public final class Audio: @unchecked Sendable {
    public static let defaultSampleRate: Int = 48_000

    public let sampleRate: Int
    public let playbackChannels: Int
    public var events: AudioEvents = AudioEvents()

    private var defaultStartOptions: AudioStartOptions?
    private var outputSink: (any AudioOutputSink)?
    private var isDisposed: Bool = false
    private var playbackStarted: Bool = false
    private var mixerStarted: Bool = false

    private var masterVolumeValue: Double = 1.0
    private var nextSoundId: AudioSound = 1
    private var nextVoiceId: AudioVoice = 1
    private var nextGroupId: AudioGroup = 1
    private var nextStreamId: UInt32 = 1

    private var sounds: [AudioSound: AudioPCMBuffer] = [:]
    private var groupsByName: [String: AudioGroup] = [:]
    private var groupVolumes: [AudioGroup: Double] = [0: 1.0]
    private var voices: [AudioVoice: MixerVoice] = [:]

    private var activeDisposables: [UInt32: () -> Void] = [:]

    private var tapEnabled: Bool = false
    private var tapRing: FloatRingBuffer? = nil

    private var captureStarted: Bool = false
    private var captureOwnedByStream: Bool = false
    private var captureRing: FloatRingBuffer? = nil
    private var captureStats: AudioCaptureStats = AudioCaptureStats()

    private var playbackDevices: [AudioPlaybackDevice] = [
        AudioPlaybackDevice(index: 0, name: "Default Playback Output", isDefault: true)
    ]
    private var selectedPlaybackDeviceIndex: Int? = nil

    private var captureDevices: [AudioCaptureDevice] = [
        AudioCaptureDevice(index: 0, name: "Default Capture Input", isDefault: true)
    ]
    private var selectedCaptureDeviceIndex: Int? = nil

    private var framesMixedTotal: UInt64 = 0
    private var lastPeakLevel: Float = 0
    private var lastRmsLevel: Float = 0

    // parity: core/src/audio.ts#Audio.create [status=implemented hash=4bd4c3138f18]
    public static func create(_ options: AudioSetupOptions = AudioSetupOptions()) throws(AudioInitializationError) -> Audio {
        if let sr = options.sampleRate, sr < 0 {
            throw AudioInitializationError(action: .createAudioEngine, message: "sampleRate must be non-negative")
        }
        return Audio(options: options)
    }

    public init(options: AudioSetupOptions = AudioSetupOptions()) {
        let sr = (options.sampleRate ?? 0) > 0 ? options.sampleRate! : Self.defaultSampleRate
        self.sampleRate = sr
        self.playbackChannels = max(1, options.playbackChannels ?? 2)
        self.defaultStartOptions = options.startOptions
        self.outputSink = options.outputSink

        if options.autoStart ?? false {
            self.playbackStarted = true
            self.mixerStarted = true
        }
    }

    /// Attaches or replaces the pluggable `AudioOutputSink` receiving mixed frames.
    public func attachOutputSink(_ sink: (any AudioOutputSink)?) {
        outputSink = sink
    }

    /// Configures virtual playback/capture devices (useful for headless/test environments).
    public func setVirtualDevices(
        playback: [AudioPlaybackDevice]? = nil,
        capture: [AudioCaptureDevice]? = nil
    ) {
        if let playback { playbackDevices = playback }
        if let capture { captureDevices = capture }
    }

    private func emitError(_ action: AudioAction, status: Int? = nil, message: String) {
        let error = AudioInitializationError(action: .createAudioEngine, message: message, status: status)
        events.onError?(error, AudioErrorContext(action: action, status: status))
    }

    // MARK: - Lifecycle

    // parity: core/src/audio.ts#Audio.start [status=implemented hash=32be02d09246]
    @discardableResult
    public func start(_ options: AudioStartOptions? = nil) -> Bool {
        if playbackStarted { return true }
        guard !isDisposed else {
            emitError(.start, message: "Audio engine unavailable during start")
            return false
        }
        if let options {
            defaultStartOptions = options
        }
        playbackStarted = true
        mixerStarted = true
        events.onStarted?()
        return true
    }

    // parity: core/src/audio.ts#Audio.startMixer [status=implemented hash=3ca89d5d2a66]
    @discardableResult
    public func startMixer() -> Bool {
        if mixerStarted { return true }
        guard !isDisposed else {
            emitError(.startMixer, message: "Audio engine unavailable during startMixer")
            return false
        }
        mixerStarted = true
        events.onMixerStarted?()
        return true
    }

    // parity: core/src/audio.ts#Audio.stop [status=implemented hash=35ada2f3eb7e]
    @discardableResult
    public func stop() -> Bool {
        if !mixerStarted { return true }
        guard !isDisposed else {
            emitError(.stop, message: "Audio engine unavailable during stop")
            return false
        }
        playbackStarted = false
        mixerStarted = false
        events.onStopped?()
        return true
    }

    // parity: core/src/audio.ts#Audio.isStarted [status=implemented hash=5aac107f7076]
    public func isStarted() -> Bool {
        playbackStarted
    }

    // parity: core/src/audio.ts#Audio.isMixerStarted [status=implemented hash=9e285a462d2c]
    public func isMixerStarted() -> Bool {
        mixerStarted
    }

    // MARK: - Sound Loading & Unloading

    /// Loads an `AudioPCMBuffer` directly into the engine (automatically resampling to engine sampleRate if needed).
    public func loadPCMBuffer(_ buffer: AudioPCMBuffer) -> AudioSound? {
        guard !isDisposed else {
            emitError(.loadSound, message: "Audio engine unavailable during loadSound")
            return nil
        }
        let prepared = buffer.sampleRate == sampleRate ? buffer : buffer.resampled(to: sampleRate)
        let id = nextSoundId
        nextSoundId &+= 1
        sounds[id] = prepared
        return id
    }

    // parity: core/src/audio.ts#Audio.loadSound [status=implemented hash=5b2c43bfcd06]
    public func loadSound(_ data: [UInt8]) -> AudioSound? {
        guard !isDisposed else {
            emitError(.loadSound, message: "Audio engine unavailable during loadSound")
            return nil
        }
        guard !data.isEmpty else {
            emitError(.loadSound, status: -1, message: "Audio loadSound received empty data")
            return nil
        }
        if let wavBuffer = try? WAVCodec.decode(data) {
            return loadPCMBuffer(wavBuffer)
        }
        // Fallback: interpret raw little-endian float32 PCM mono samples when size is a multiple of 4.
        if data.count % 4 == 0 {
            let samples = PCMConverter.bytesLEToFloat32(data)
            let buffer = AudioPCMBuffer(sampleRate: sampleRate, channels: 1, samples: samples)
            return loadPCMBuffer(buffer)
        }
        emitError(.loadSound, status: -2, message: "Unsupported sound byte format")
        return nil
    }

    // parity: core/src/audio.ts#Audio.loadSoundFile [status=implemented hash=34d38def755a]
    public func loadSoundFile(
        _ filePath: String,
        reader: (@Sendable (String) async throws -> [UInt8])? = nil
    ) async -> AudioSound? {
        guard let reader else {
            emitError(.loadSoundFile, message: "No file reader provided for '\(filePath)' in pure OpenTUICore")
            return nil
        }
        do {
            let bytes = try await reader(filePath)
            return loadSound(bytes)
        } catch {
            emitError(.loadSoundFile, message: "Failed to read file '\(filePath)': \(error)")
            return nil
        }
    }

    // parity: core/src/audio.ts#Audio.unloadSound [status=implemented hash=49ab63cf25a5]
    @discardableResult
    public func unloadSound(_ sound: AudioSound) -> Bool {
        guard !isDisposed else {
            emitError(.unloadSound, message: "Audio engine unavailable during unloadSound")
            return false
        }
        guard sounds.removeValue(forKey: sound) != nil else {
            emitError(.unloadSound, status: -1, message: "Sound \(sound) not found")
            return false
        }
        // Stop any voices referencing this unloaded sound
        for (voiceId, voice) in voices where voice.soundId == sound {
            voices.removeValue(forKey: voiceId)
        }
        return true
    }

    /// Returns the loaded PCM buffer for inspection, if present.
    public func soundBuffer(for sound: AudioSound) -> AudioPCMBuffer? {
        sounds[sound]
    }

    // MARK: - Mixer Groups & Master Controls

    // parity: core/src/audio.ts#Audio.group [status=implemented hash=b64a8519c8c8]
    public func group(_ name: String) -> AudioGroup? {
        guard !isDisposed else {
            emitError(.group, message: "Audio engine unavailable during group")
            return nil
        }
        if let existing = groupsByName[name] {
            return existing
        }
        let id = nextGroupId
        nextGroupId &+= 1
        groupsByName[name] = id
        groupVolumes[id] = 1.0
        return id
    }

    // parity: core/src/audio.ts#Audio.setGroupVolume [status=implemented hash=daa2ba6bf1ae]
    @discardableResult
    public func setGroupVolume(_ group: AudioGroup, volume: Double) -> Bool {
        guard !isDisposed else {
            emitError(.setGroupVolume, message: "Audio engine unavailable during setGroupVolume")
            return false
        }
        guard volume.isFinite && volume >= 0 else {
            emitError(.setGroupVolume, status: -1, message: "Invalid group volume")
            return false
        }
        groupVolumes[group] = volume
        return true
    }

    public func groupVolume(_ group: AudioGroup) -> Double {
        groupVolumes[group] ?? 1.0
    }

    // parity: core/src/audio.ts#Audio.setMasterVolume [status=implemented hash=3d60023270d7]
    @discardableResult
    public func setMasterVolume(_ volume: Double) -> Bool {
        guard !isDisposed else {
            emitError(.setMasterVolume, message: "Audio engine unavailable during setMasterVolume")
            return false
        }
        guard volume.isFinite && volume >= 0 else {
            emitError(.setMasterVolume, status: -1, message: "Invalid master volume")
            return false
        }
        masterVolumeValue = volume
        return true
    }

    public var masterVolume: Double {
        masterVolumeValue
    }

    // MARK: - Voice Playback, Transport, Gain, Pan, Pitch, Loop, Fade & Seek

    // parity: core/src/audio.ts#Audio.play [status=implemented hash=d9fecbccec2d]
    public func play(_ sound: AudioSound, options: AudioPlayOptions = AudioPlayOptions()) -> AudioVoice? {
        guard !isDisposed else {
            emitError(.play, message: "Audio engine unavailable during play")
            return nil
        }
        guard sounds[sound] != nil else {
            emitError(.play, status: -1, message: "Unknown sound id \(sound)")
            return nil
        }
        let targetVolume = max(0.0, options.volume ?? 1.0)
        let pan = max(-1.0, min(1.0, options.pan ?? 0.0))
        let pitch = max(0.01, options.pitch ?? 1.0)
        let groupId = options.groupId ?? 0
        let loop = options.loop ?? false

        var initialVolume = targetVolume
        var fade: FadeRamp? = nil
        if let fadeIn = options.fadeInSeconds, fadeIn > 0 {
            let totalFrames = max(1, Int((fadeIn * Double(sampleRate)).rounded()))
            initialVolume = 0.0
            fade = FadeRamp(
                startVolume: 0.0,
                targetVolume: targetVolume,
                totalFrames: totalFrames,
                elapsedFrames: 0,
                stopWhenComplete: false
            )
        }

        let voiceId = nextVoiceId
        nextVoiceId &+= 1
        voices[voiceId] = MixerVoice(
            id: voiceId,
            soundId: sound,
            volume: initialVolume,
            pan: pan,
            pitch: pitch,
            loop: loop,
            groupId: groupId,
            framePosition: 0.0,
            isPaused: false,
            fade: fade
        )
        return voiceId
    }

    // parity: core/src/audio.ts#Audio.stopVoice [status=implemented hash=064e1bd0e6e7]
    @discardableResult
    public func stopVoice(_ voice: AudioVoice) -> Bool {
        guard !isDisposed else {
            emitError(.stopVoice, message: "Audio engine unavailable during stopVoice")
            return false
        }
        return voices.removeValue(forKey: voice) != nil
    }

    /// Pauses an active voice without losing its playback position.
    @discardableResult
    public func pauseVoice(_ voice: AudioVoice) -> Bool {
        guard !isDisposed, var existing = voices[voice] else { return false }
        existing.isPaused = true
        voices[voice] = existing
        return true
    }

    /// Resumes a paused voice from its saved playback position.
    @discardableResult
    public func resumeVoice(_ voice: AudioVoice) -> Bool {
        guard !isDisposed, var existing = voices[voice] else { return false }
        existing.isPaused = false
        voices[voice] = existing
        return true
    }

    /// Seeks an active voice to a specific sample frame position.
    @discardableResult
    public func seekVoice(_ voice: AudioVoice, toFrame frame: Double) -> Bool {
        guard !isDisposed, frame.isFinite, var existing = voices[voice], let buffer = sounds[existing.soundId] else {
            return false
        }
        let maxFrame = Double(max(0, buffer.frameCount))
        existing.framePosition = max(0.0, min(maxFrame, frame))
        voices[voice] = existing
        return true
    }

    /// Seeks an active voice to a timestamp in seconds.
    @discardableResult
    public func seekVoice(_ voice: AudioVoice, toSeconds seconds: Double) -> Bool {
        seekVoice(voice, toFrame: seconds * Double(sampleRate))
    }

    /// Updates voice volume immediately.
    @discardableResult
    public func setVoiceVolume(_ voice: AudioVoice, volume: Double) -> Bool {
        guard !isDisposed, volume.isFinite, volume >= 0, var existing = voices[voice] else { return false }
        existing.volume = volume
        existing.fade = nil
        voices[voice] = existing
        return true
    }

    /// Updates voice stereo pan (`-1.0` = hard left, `0.0` = center, `+1.0` = hard right).
    @discardableResult
    public func setVoicePan(_ voice: AudioVoice, pan: Double) -> Bool {
        guard !isDisposed, pan.isFinite, var existing = voices[voice] else { return false }
        existing.pan = max(-1.0, min(1.0, pan))
        voices[voice] = existing
        return true
    }

    /// Updates voice playback rate / pitch multiplier (`1.0` = normal speed, `2.0` = octave up).
    @discardableResult
    public func setVoicePitch(_ voice: AudioVoice, pitch: Double) -> Bool {
        guard !isDisposed, pitch.isFinite, pitch > 0, var existing = voices[voice] else { return false }
        existing.pitch = pitch
        voices[voice] = existing
        return true
    }

    /// Enables or disables seamless looping on a voice.
    @discardableResult
    public func setVoiceLoop(_ voice: AudioVoice, loop: Bool) -> Bool {
        guard !isDisposed, var existing = voices[voice] else { return false }
        existing.loop = loop
        voices[voice] = existing
        return true
    }

    /// Smoothly ramps voice gain to `targetVolume` over `durationSeconds`.
    @discardableResult
    public func fadeVoice(
        _ voice: AudioVoice,
        to targetVolume: Double,
        durationSeconds: Double,
        stopWhenComplete: Bool = false
    ) -> Bool {
        guard !isDisposed, targetVolume.isFinite, targetVolume >= 0, durationSeconds.isFinite,
              var existing = voices[voice]
        else { return false }
        let totalFrames = max(1, Int((max(0.0, durationSeconds) * Double(sampleRate)).rounded()))
        existing.fade = FadeRamp(
            startVolume: existing.volume,
            targetVolume: targetVolume,
            totalFrames: totalFrames,
            elapsedFrames: 0,
            stopWhenComplete: stopWhenComplete
        )
        voices[voice] = existing
        return true
    }

    // parity: core/src/audio.ts#Audio.setVoiceGroup [status=implemented hash=dd8c4e531e97]
    @discardableResult
    public func setVoiceGroup(_ voice: AudioVoice, group: AudioGroup) -> Bool {
        guard !isDisposed else {
            emitError(.setVoiceGroup, message: "Audio engine unavailable during setVoiceGroup")
            return false
        }
        guard var existing = voices[voice] else {
            emitError(.setVoiceGroup, status: -1, message: "Unknown voice id \(voice)")
            return false
        }
        existing.groupId = group
        voices[voice] = existing
        return true
    }

    public func isVoicePlaying(_ voice: AudioVoice) -> Bool {
        guard let v = voices[voice] else { return false }
        return !v.isPaused
    }

    public func isVoicePaused(_ voice: AudioVoice) -> Bool {
        voices[voice]?.isPaused ?? false
    }

    public func voicePositionFrames(_ voice: AudioVoice) -> Double? {
        voices[voice]?.framePosition
    }

    public func voicePositionSeconds(_ voice: AudioVoice) -> Double? {
        voices[voice].map { $0.framePosition / Double(sampleRate) }
    }

    // MARK: - PCM Mixer

    // parity: core/src/audio.ts#Audio.mixFrames [status=implemented hash=b0adff4dc322]
    public func mixFrames(_ frameCount: Int, channels: Int = 2) -> [Float]? {
        guard !isDisposed else {
            emitError(.mixFrames, message: "Audio engine unavailable during mixFrames")
            return nil
        }
        guard frameCount >= 0 && channels >= 1 else {
            emitError(.mixFrames, status: -1, message: "Invalid mixFrames arguments")
            return nil
        }

        var output = Array<Float>(repeating: 0.0, count: frameCount * channels)
        let activeVoiceIds = voices.keys.sorted()
        var finishedVoices: [AudioVoice] = []
        let shouldClip = !(defaultStartOptions?.noClip ?? false)

        for voiceId in activeVoiceIds {
            guard var voice = voices[voiceId], !voice.isPaused else { continue }
            guard let buffer = sounds[voice.soundId], buffer.frameCount > 0 else {
                finishedVoices.append(voiceId)
                continue
            }

            let srcFrames = buffer.frameCount
            let srcChannels = buffer.channels
            let groupGain = groupVolumes[voice.groupId] ?? 1.0

            // Equal-power stereo panning law: pan in [-1, +1] -> angle in [0, pi/2]
            let panNorm = (voice.pan + 1.0) * 0.5
            let leftPanGain = audioCos(panNorm * audioHalfPi) * 1.4142135623730951
            let rightPanGain = audioSin(panNorm * audioHalfPi) * 1.4142135623730951

            var voiceEnded = false

            for frame in 0..<frameCount {
                if var fade = voice.fade {
                    let progress = min(1.0, Double(fade.elapsedFrames) / Double(fade.totalFrames))
                    voice.volume = fade.startVolume + (fade.targetVolume - fade.startVolume) * progress
                    fade.elapsedFrames += 1
                    if fade.elapsedFrames >= fade.totalFrames {
                        voice.volume = fade.targetVolume
                        let shouldStop = fade.stopWhenComplete
                        voice.fade = nil
                        if shouldStop {
                            voiceEnded = true
                            break
                        }
                    } else {
                        voice.fade = fade
                    }
                }

                if voice.framePosition >= Double(srcFrames) {
                    if voice.loop {
                        voice.framePosition = voice.framePosition.truncatingRemainder(dividingBy: Double(srcFrames))
                    } else {
                        voiceEnded = true
                        break
                    }
                }

                let idx0 = Int(voice.framePosition)
                let frac = Float(voice.framePosition - Double(idx0))
                let idx1: Int
                if idx0 + 1 < srcFrames {
                    idx1 = idx0 + 1
                } else {
                    idx1 = voice.loop ? 0 : idx0
                }

                let totalGain = voice.volume * groupGain * masterVolumeValue

                if channels == 1 {
                    var mono: Float = 0
                    for ch in 0..<srcChannels {
                        let s0 = buffer.samples[idx0 * srcChannels + ch]
                        let s1 = buffer.samples[idx1 * srcChannels + ch]
                        mono += s0 + (s1 - s0) * frac
                    }
                    mono /= Float(srcChannels)
                    output[frame] += Float(Double(mono) * totalGain)
                } else if channels == 2 {
                    let s0L = buffer.samples[idx0 * srcChannels]
                    let s1L = buffer.samples[idx1 * srcChannels]
                    let sampleL = s0L + (s1L - s0L) * frac

                    let rightCh = srcChannels > 1 ? 1 : 0
                    let s0R = buffer.samples[idx0 * srcChannels + rightCh]
                    let s1R = buffer.samples[idx1 * srcChannels + rightCh]
                    let sampleR = s0R + (s1R - s0R) * frac

                    output[frame * 2] += Float(Double(sampleL) * totalGain * leftPanGain)
                    output[frame * 2 + 1] += Float(Double(sampleR) * totalGain * rightPanGain)
                } else {
                    for ch in 0..<channels {
                        let srcCh = ch % srcChannels
                        let s0 = buffer.samples[idx0 * srcChannels + srcCh]
                        let s1 = buffer.samples[idx1 * srcChannels + srcCh]
                        let sample = s0 + (s1 - s0) * frac
                        output[frame * channels + ch] += Float(Double(sample) * totalGain)
                    }
                }

                voice.framePosition += voice.pitch
                if voice.framePosition >= Double(srcFrames) {
                    if voice.loop {
                        voice.framePosition = voice.framePosition.truncatingRemainder(dividingBy: Double(srcFrames))
                    } else {
                        voiceEnded = true
                        break
                    }
                }
            }

            if voiceEnded {
                finishedVoices.append(voiceId)
            } else {
                voices[voiceId] = voice
            }
        }

        for id in finishedVoices {
            voices.removeValue(forKey: id)
        }

        if shouldClip {
            for i in 0..<output.count {
                output[i] = PCMConverter.clampSample(output[i])
            }
        }

        let meter = AudioLevelMeter.measure(output)
        lastPeakLevel = meter.peak
        lastRmsLevel = meter.rms
        framesMixedTotal &+= UInt64(frameCount)

        if tapEnabled {
            if tapRing == nil || tapRing?.channels != channels {
                tapRing = FloatRingBuffer(capacityFrames: max(frameCount, 8192), channels: channels)
            }
            _ = tapRing?.write(output)
        }

        outputSink?.writeFrames(output, frameCount: frameCount, channels: channels, sampleRate: sampleRate)
        return output
    }

    // MARK: - Tap Monitoring

    // parity: core/src/audio.ts#Audio.enableTap [status=implemented hash=cef301c72076]
    @discardableResult
    public func enableTap(capacityFrames: Int = 8192) -> Bool {
        guard !isDisposed else {
            emitError(.enableTap, message: "Audio engine unavailable during enableTap")
            return false
        }
        guard capacityFrames > 0 else {
            emitError(.enableTap, status: -1, message: "Tap capacityFrames must be positive")
            return false
        }
        tapEnabled = true
        tapRing = FloatRingBuffer(capacityFrames: capacityFrames, channels: playbackChannels)
        return true
    }

    // parity: core/src/audio.ts#Audio.disableTap [status=implemented hash=33219856d264]
    @discardableResult
    public func disableTap() -> Bool {
        guard !isDisposed else {
            emitError(.enableTap, message: "Audio engine unavailable during disableTap")
            return false
        }
        tapEnabled = false
        tapRing = nil
        return true
    }

    // parity: core/src/audio.ts#Audio.readTapFrames [status=implemented hash=96d7e569d604]
    public func readTapFrames(_ frameCount: Int, channels: Int = 2) -> AudioCaptureReadResult? {
        guard !isDisposed else {
            emitError(.readTapFrames, message: "Audio engine unavailable during readTapFrames")
            return nil
        }
        guard tapEnabled, var ring = tapRing else {
            emitError(.readTapFrames, status: -1, message: "Audio tap is not enabled")
            return nil
        }
        let result = ring.read(maxFrames: frameCount)
        tapRing = ring
        return AudioCaptureReadResult(frames: result.frames, framesRead: result.framesRead)
    }

    // MARK: - Streaming Playback

    // parity: core/src/audio.ts#Audio.playStream [status=implemented hash=9d5e0745a574]
    public func playStream<M: Sendable>(
        _ source: AudioStreamBody,
        options: AudioStreamBodyOptions<M> = AudioStreamBodyOptions()
    ) async throws -> AudioStream<M> {
        let demuxFactory = options.demuxer
        let stream = try createManagedStream(options: options.stream, metadataType: M.self)
        let demuxer = demuxFactory?()
        if let initial = demuxer?.initialMetadata {
            stream.updateMetadata(initial)
        }
        try await pumpStreamBody(source, into: stream, demuxer: demuxer)
        return stream
    }

    // parity: core/src/audio.ts#Audio.playStreamUrl [status=implemented hash=334cd2b05ca6]
    public func playStreamUrl(
        _ url: String,
        options: AudioStreamUrlOptions = AudioStreamUrlOptions()
    ) async throws -> AudioStream<AudioStreamMetadata> {
        guard !isDisposed else {
            throw AudioStreamError(message: "Audio engine unavailable during stream playback", context: AudioStreamErrorContext(action: .create))
        }
        let format = options.stream.format ?? .mp3
        let encoding = options.metadataEncoding ?? "iso-8859-1"
        guard IcyMetadataEncoding(label: encoding) != nil else {
            throw AudioStreamError(
                message: "Unsupported metadataEncoding: \(encoding)",
                context: AudioStreamErrorContext(action: .demuxer)
            )
        }
        guard let fetcher = options.fetcher else {
            throw AudioStreamError(
                message: "No fetcher configured for playStreamUrl in pure OpenTUICore",
                context: AudioStreamErrorContext(action: .fetch)
            )
        }

        var reqHeaders = options.headers ?? [:]
        if !reqHeaders.keys.contains(where: { $0.lowercased() == "icy-metadata" }) {
            reqHeaders["Icy-MetaData"] = "1"
        }

        let response = try await fetcher(url, reqHeaders)
        guard (200...299).contains(response.status) else {
            throw AudioStreamError(
                message: "Audio stream request failed with HTTP \(response.status)",
                context: AudioStreamErrorContext(action: .response, status: response.status)
            )
        }

        let contentType = response.headers.first(where: { $0.key.lowercased() == "content-type" })?.value
        let policy = options.contentTypePolicy ?? .validate
        let accepted: Bool
        if contentType == nil {
            accepted = true
        } else {
            switch policy {
            case .ignore:
                accepted = true
            case .validate:
                accepted = Self.isAllowedContentType(format: format, value: contentType!)
            case .custom(let fn):
                accepted = fn(
                    AudioStreamContentTypeContext(
                        format: format,
                        contentType: contentType,
                        status: response.status,
                        url: response.url.isEmpty ? url : response.url
                    )
                )
            }
        }
        guard accepted else {
            throw AudioStreamError(
                message: "Unsupported audio stream Content-Type: \(contentType ?? "")",
                context: AudioStreamErrorContext(action: .response, status: response.status)
            )
        }

        let demuxer: IcyStreamDemuxer?
        do {
            demuxer = try selectAudioStreamDemuxer(headers: response.headers, metadataEncoding: encoding)
        } catch {
            throw AudioStreamError(
                message: "\(error)",
                context: AudioStreamErrorContext(action: .response, status: response.status)
            )
        }

        let stream = try createManagedStream(options: options.stream, metadataType: AudioStreamMetadata.self)
        if let initial = demuxer?.initialMetadata {
            stream.updateMetadata(initial)
        }
        try await pumpStreamBody(response.body, into: stream, demuxer: demuxer)
        return stream
    }

    // parity: core/src/audio.ts#Audio.playStreamSource [status=implemented hash=5115a6f82b36]
    public func playStreamSource<C: AudioStreamConnector, M: Sendable>(
        _ connector: C,
        options: AudioStreamSourceOptions<C.Info, M> = AudioStreamSourceOptions()
    ) async throws -> AudioStream<M> {
        guard !isDisposed else {
            throw AudioStreamError(message: "Audio engine unavailable during stream playback", context: AudioStreamErrorContext(action: .create))
        }
        let connection = try await connector.connect(context: AudioStreamConnectContext(attempt: 0))
        let demuxer = try options.demuxer?(connection.info)
        let stream = try createManagedStream(options: options.stream, metadataType: M.self)
        if let initial = demuxer?.initialMetadata {
            stream.updateMetadata(initial)
        }
        try await pumpStreamBody(connection.body, into: stream, demuxer: demuxer)
        await connection.close?()
        return stream
    }

    private func createManagedStream<M: Sendable>(
        options: AudioStreamOptions,
        metadataType: M.Type
    ) throws -> AudioStream<M> {
        guard !isDisposed else {
            throw AudioStreamError(message: "Audio engine unavailable during stream playback", context: AudioStreamErrorContext(action: .create))
        }
        let format = options.format ?? .mp3
        let streamSampleRate: Int
        let streamChannels: Int
        if format == .pcm {
            guard options.sampleFormat == .float32 else {
                throw AudioStreamError(message: "PCM sampleFormat must be 'f32le'", context: AudioStreamErrorContext(action: .create))
            }
            guard let sr = options.sampleRate, sr >= 8000 && sr <= 192000 else {
                throw AudioStreamError(message: "PCM sampleRate must be between 8000 and 192000 Hz", context: AudioStreamErrorContext(action: .create))
            }
            guard let ch = options.channels, ch == 1 || ch == 2 else {
                throw AudioStreamError(message: "PCM channels must be 1 or 2", context: AudioStreamErrorContext(action: .create))
            }
            streamSampleRate = sr
            streamChannels = ch
        } else {
            streamSampleRate = sampleRate
            streamChannels = playbackChannels
        }

        let capacityMs = max(1, options.buffer?.capacityMs ?? 2000)
        let capacityFrames = max(1, (streamSampleRate * capacityMs) / 1000)
        let id = nextStreamId
        nextStreamId &+= 1

        let stream = AudioStream<M>(
            owner: self,
            streamId: id,
            format: format,
            sampleRate: streamSampleRate,
            channels: streamChannels,
            capacityFrames: capacityFrames,
            volume: options.volume ?? 1.0,
            pan: options.pan ?? 0.0,
            groupId: options.groupId ?? 0,
            removeFromOwner: { [weak self] in
                self?.activeDisposables.removeValue(forKey: id)
            }
        )
        activeDisposables[id] = { stream.dispose() }
        return stream
    }

    private func pumpStreamBody<M: Sendable>(
        _ body: AudioStreamBody,
        into stream: AudioStream<M>,
        demuxer: (any AudioStreamDemuxer<M>)?
    ) async throws {
        func handleChunk(_ chunk: [UInt8]) {
            guard !chunk.isEmpty else { return }
            if let demuxer {
                for output in demuxer.push(chunk) {
                    switch output {
                    case .audio(let audioBytes):
                        stream.writeBytes(audioBytes)
                    case .metadata(let meta):
                        stream.updateMetadata(meta)
                    }
                }
            } else {
                stream.writeBytes(chunk)
            }
        }

        switch body {
        case .chunks(let chunks):
            for chunk in chunks {
                handleChunk(chunk)
            }
        case .asyncStream(let asyncStream):
            for await chunk in asyncStream {
                handleChunk(chunk)
            }
        }

        if let demuxer {
            let flushed = try demuxer.flush()
            for output in flushed {
                switch output {
                case .audio(let audioBytes):
                    stream.writeBytes(audioBytes)
                case .metadata(let meta):
                    stream.updateMetadata(meta)
                }
            }
        }
        stream.markEnded()
    }

    private static func isAllowedContentType(format: AudioStreamFormat, value: String) -> Bool {
        let base = value.split(separator: ";", maxSplits: 1).first?
            .trimmingSpaces()
            .lowercased() ?? ""
        switch format {
        case .mp3:
            return base == "audio/mpeg" || base == "audio/mp3" || base == "application/octet-stream" || base == "application/mp3"
        case .flac:
            return base == "audio/flac" || base == "audio/x-flac" || base == "application/octet-stream"
        case .pcm:
            return base == "audio/pcm" || base == "application/octet-stream"
        }
    }

    // MARK: - Playback Device Enumeration & Selection

    // parity: core/src/audio.ts#Audio.listPlaybackDevices [status=implemented hash=25ba6c05f9f4]
    public func listPlaybackDevices() -> [AudioPlaybackDevice]? {
        guard !isDisposed else {
            emitError(.listPlaybackDevices, message: "Audio engine unavailable during listPlaybackDevices")
            return nil
        }
        return playbackDevices
    }

    // parity: core/src/audio.ts#Audio.selectPlaybackDevice [status=implemented hash=aecfbe973050]
    @discardableResult
    public func selectPlaybackDevice(_ index: Int) -> Bool {
        guard !isDisposed else {
            emitError(.selectPlaybackDevice, message: "Audio engine unavailable during selectPlaybackDevice")
            return false
        }
        guard index >= 0 && index < playbackDevices.count else {
            emitError(.selectPlaybackDevice, status: -1, message: "Playback device index out of range: \(index)")
            return false
        }
        selectedPlaybackDeviceIndex = index
        return true
    }

    // parity: core/src/audio.ts#Audio.clearPlaybackDeviceSelection [status=implemented hash=dff4c3c7af2b]
    public func clearPlaybackDeviceSelection() {
        guard !isDisposed else {
            emitError(.clearPlaybackDeviceSelection, message: "Audio engine unavailable during clearPlaybackDeviceSelection")
            return
        }
        selectedPlaybackDeviceIndex = nil
    }

    // MARK: - Capture Ring Buffer, Capture Streams & WAV Recording

    // parity: core/src/audio.ts#Audio.listCaptureDevices [status=implemented hash=b7babcaec509]
    public func listCaptureDevices() -> [AudioCaptureDevice]? {
        guard !isDisposed else {
            emitError(.listCaptureDevices, message: "Audio engine unavailable during listCaptureDevices")
            return nil
        }
        return captureDevices
    }

    // parity: core/src/audio.ts#Audio.selectCaptureDevice [status=implemented hash=3affad4aa69f]
    @discardableResult
    public func selectCaptureDevice(_ index: Int) -> Bool {
        guard !isDisposed else {
            emitError(.selectCaptureDevice, message: "Audio engine unavailable during selectCaptureDevice")
            return false
        }
        guard !captureOwnedByStream else {
            emitError(.selectCaptureDevice, message: "Audio selectCaptureDevice failed: capture is owned by a stream")
            return false
        }
        guard index >= 0 && index < captureDevices.count else {
            emitError(.selectCaptureDevice, status: -1, message: "Capture device index out of range: \(index)")
            return false
        }
        selectedCaptureDeviceIndex = index
        return true
    }

    // parity: core/src/audio.ts#Audio.clearCaptureDeviceSelection [status=implemented hash=35e666025d00]
    public func clearCaptureDeviceSelection() {
        guard !isDisposed else {
            emitError(.clearCaptureDeviceSelection, message: "Audio engine unavailable during clearCaptureDeviceSelection")
            return
        }
        guard !captureOwnedByStream else {
            emitError(.clearCaptureDeviceSelection, message: "Audio clearCaptureDeviceSelection failed: capture is owned by a stream")
            return
        }
        selectedCaptureDeviceIndex = nil
    }

    // parity: core/src/audio.ts#Audio.startCapture [status=implemented hash=ebbe33dfd64c]
    @discardableResult
    public func startCapture(_ options: AudioCaptureOptions = AudioCaptureOptions()) -> Bool {
        guard !isDisposed else {
            emitError(.startCapture, message: "Audio engine unavailable during startCapture")
            return false
        }
        guard !captureOwnedByStream else {
            emitError(.startCapture, message: "Audio startCapture failed: capture is owned by a stream")
            return false
        }
        let channels = max(1, options.channels ?? 1)
        let capacityFrames = max(1, options.capacityFrames ?? sampleRate)
        return internalStartCapture(channels: channels, capacityFrames: capacityFrames)
    }

    private func internalStartCapture(channels: Int, capacityFrames: Int) -> Bool {
        captureRing = FloatRingBuffer(capacityFrames: capacityFrames, channels: channels)
        captureStats = AudioCaptureStats(
            sampleRate: sampleRate,
            channels: channels,
            capacityFrames: capacityFrames,
            bufferedFrames: 0,
            framesReceived: 0,
            framesRead: 0,
            framesDropped: 0
        )
        captureStarted = true
        events.onCaptureStarted?()
        return true
    }

    /// Pushes interleaved float32 input frames into the capture ring buffer (for platform backends and tests).
    @discardableResult
    public func pushCaptureFrames(_ samples: [Float]) -> Int {
        guard captureStarted, var ring = captureRing else { return 0 }
        let (written, dropped) = ring.write(samples)
        captureRing = ring
        captureStats.framesReceived &+= UInt64(written)
        captureStats.framesDropped &+= UInt64(dropped)
        captureStats.bufferedFrames = ring.bufferedFrames
        return written
    }

    // parity: core/src/audio.ts#Audio.isCapturing [status=implemented hash=9aad5161e194]
    public func isCapturing() -> Bool {
        captureStarted && !isDisposed
    }

    // parity: core/src/audio.ts#Audio.readCaptureFrames [status=implemented hash=4048c2586581]
    public func readCaptureFrames(_ frameCount: Int) -> AudioCaptureReadResult? {
        guard !isDisposed else {
            emitError(.readCaptureFrames, message: "Audio engine unavailable during readCaptureFrames")
            return nil
        }
        guard !captureOwnedByStream else {
            emitError(.readCaptureFrames, message: "Audio readCaptureFrames failed: capture is owned by a stream")
            return nil
        }
        guard frameCount > 0, captureRing != nil else {
            emitError(.readCaptureFrames, status: -4, message: "Capture buffer is unavailable")
            return nil
        }
        return internalReadCapture(frameCount: frameCount)
    }

    internal func internalReadCapture(frameCount: Int) -> AudioCaptureReadResult {
        guard var ring = captureRing else {
            return AudioCaptureReadResult(frames: [], framesRead: 0)
        }
        let result = ring.read(maxFrames: frameCount)
        captureRing = ring
        captureStats.framesRead &+= UInt64(result.framesRead)
        captureStats.bufferedFrames = ring.bufferedFrames
        return AudioCaptureReadResult(frames: result.frames, framesRead: result.framesRead)
    }

    // parity: core/src/audio.ts#Audio.getCaptureStats [status=implemented hash=575c35663089]
    public func getCaptureStats() -> AudioCaptureStats? {
        guard !isDisposed else {
            emitError(.getCaptureStats, message: "Audio engine unavailable during getCaptureStats")
            return nil
        }
        return internalCaptureStats()
    }

    internal func internalCaptureStats() -> AudioCaptureStats? {
        guard !isDisposed else { return nil }
        captureStats.bufferedFrames = captureRing?.bufferedFrames ?? 0
        return captureStats
    }

    // parity: core/src/audio.ts#Audio.stopCapture [status=implemented hash=3fc9a54e9cd2]
    @discardableResult
    public func stopCapture() -> Bool {
        guard !isDisposed else {
            emitError(.stopCapture, message: "Audio engine unavailable during stopCapture")
            return false
        }
        guard !captureOwnedByStream else {
            emitError(.stopCapture, message: "Audio stopCapture failed: capture is owned by a stream")
            return false
        }
        return internalStopCapture()
    }

    internal func internalStopCapture() -> Bool {
        guard captureStarted else { return true }
        captureStarted = false
        events.onCaptureStopped?()
        return true
    }

    // parity: core/src/audio.ts#Audio.openCapture [status=implemented hash=b7235e985bf7]
    public func openCapture(_ options: AudioCaptureStreamOptions = AudioCaptureStreamOptions()) throws(AudioCaptureStreamError) -> AudioCaptureStream {
        guard !isDisposed else {
            throw AudioCaptureStreamError(
                message: "Audio engine unavailable during capture stream start",
                context: AudioCaptureStreamErrorContext(action: .start)
            )
        }
        guard !captureOwnedByStream && !captureStarted else {
            throw AudioCaptureStreamError(
                message: "Audio capture ring is already in use",
                context: AudioCaptureStreamErrorContext(action: .start)
            )
        }
        let channels = max(1, options.channels ?? 1)
        let capacityFrames = max(1, options.capacityFrames ?? sampleRate)
        let chunkFrames = max(1, min(capacityFrames, options.chunkFrames ?? 2048))

        _ = internalStartCapture(channels: channels, capacityFrames: capacityFrames)
        captureOwnedByStream = true

        let id = nextStreamId
        nextStreamId &+= 1
        let stream = AudioCaptureStream(
            owner: self,
            sampleRate: sampleRate,
            channels: channels,
            capacityFrames: capacityFrames,
            chunkFrames: chunkFrames,
            removeFromOwner: { [weak self] in
                self?.captureOwnedByStream = false
                self?.activeDisposables.removeValue(forKey: id)
            }
        )
        activeDisposables[id] = { stream.dispose() }
        return stream
    }

    // parity: core/src/audio.ts#Audio.recordToFile [status=implemented hash=d53568902f7a]
    public func recordToFile(
        _ filePath: String,
        options: AudioRecordToFileOptions = AudioRecordToFileOptions(),
        onPublish: (@Sendable (String, [UInt8]) -> Void)? = nil
    ) throws(AudioRecorderError) -> AudioRecorder {
        guard !filePath.isEmpty && !filePath.contains("\0") else {
            throw AudioRecorderError(
                message: "filePath must be a nonempty string without NUL bytes",
                context: AudioRecorderErrorContext(action: .open)
            )
        }
        let channels = options.channels ?? 1
        guard channels == 1 || channels == 2 else {
            throw AudioRecorderError(
                message: "WAV recording supports only 1 or 2 channels",
                context: AudioRecorderErrorContext(action: .open)
            )
        }
        guard !isDisposed else {
            throw AudioRecorderError(
                message: "Audio engine unavailable during recorder open",
                context: AudioRecorderErrorContext(action: .open)
            )
        }
        let capture: AudioCaptureStream
        do {
            capture = try openCapture(options)
        } catch {
            throw AudioRecorderError(
                message: "Audio recorder capture start failed: \(error)",
                context: AudioRecorderErrorContext(action: .start)
            )
        }

        let id = nextStreamId
        nextStreamId &+= 1
        let recorder = AudioRecorder(
            filePath: filePath,
            capture: capture,
            onPublish: onPublish,
            removeFromOwner: { [weak self] in
                self?.activeDisposables.removeValue(forKey: id)
            }
        )
        activeDisposables[id] = { recorder.dispose() }
        return recorder
    }

    // MARK: - Telemetry & Disposal

    // parity: core/src/audio.ts#Audio.getStats [status=implemented hash=9adeb5e452b2]
    public func getStats() -> AudioStats? {
        guard !isDisposed else {
            emitError(.getStats, message: "Audio engine unavailable during getStats")
            return nil
        }
        let activeVoices = voices.values.reduce(0) { $0 + ($1.isPaused ? 0 : 1) }
        return AudioStats(
            soundsLoaded: sounds.count,
            voicesActive: activeVoices,
            framesMixed: framesMixedTotal,
            lockMisses: 0,
            lastPeak: lastPeakLevel,
            lastRms: lastRmsLevel
        )
    }

    // parity: core/src/audio.ts#Audio.dispose [status=implemented hash=282804c74e9a]
    public func dispose() {
        guard !isDisposed else { return }
        let disposers = Array(activeDisposables.values)
        activeDisposables.removeAll()
        for disposeChild in disposers {
            disposeChild()
        }
        if captureStarted {
            _ = internalStopCapture()
        }
        if mixerStarted {
            _ = stop()
        }
        voices.removeAll()
        sounds.removeAll()
        groupsByName.removeAll()
        groupVolumes.removeAll()
        tapRing = nil
        tapEnabled = false
        captureRing = nil
        captureOwnedByStream = false
        isDisposed = true
        events.onDisposed?()
    }
}

/// Convenience factory matching `core/src/audio.ts#setupAudio`.
// parity: core/src/audio.ts#setupAudio [status=implemented hash=bd9bad457186]
public func setupAudio(_ options: AudioSetupOptions = AudioSetupOptions()) throws(AudioInitializationError) -> Audio {
    try Audio.create(options)
}

private extension Substring {
    func trimmingSpaces() -> String {
        var start = startIndex
        while start < endIndex && (self[start] == " " || self[start] == "\t") {
            start = index(after: start)
        }
        var end = endIndex
        while end > start {
            let prev = index(before: end)
            if self[prev] == " " || self[prev] == "\t" {
                end = prev
            } else {
                break
            }
        }
        return String(self[start..<end])
    }
}

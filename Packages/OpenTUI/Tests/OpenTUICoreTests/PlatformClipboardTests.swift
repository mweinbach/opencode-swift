import OpenTUICore
import OpenTUITerminal
import Synchronization
import Testing

// MARK: - Test Support Backends (Never Touch Real OS Clipboard)

private final class ControlledHostClipboardBackend: HostClipboardBackend, Sendable {
    private struct State: Sendable {
        var nextReadResult: ClipboardReadResult = .empty
        var nextWriteResult: HostClipboardWriteResult = .written
        var nextClearResult: HostClipboardClearResult = .cleared
        var gate: ClipboardSyncLatch? = nil
        var disposed: Bool = false
    }

    private let state = Mutex(State())

    func setNextRead(_ result: ClipboardReadResult) {
        state.withLock { $0.nextReadResult = result }
    }

    func setNextWrite(_ result: HostClipboardWriteResult) {
        state.withLock { $0.nextWriteResult = result }
    }

    func setNextClear(_ result: HostClipboardClearResult) {
        state.withLock { $0.nextClearResult = result }
    }

    func setGate(_ latch: ClipboardSyncLatch?) {
        state.withLock { $0.gate = latch }
    }

    var isDisposed: Bool {
        state.withLock { $0.disposed }
    }

    func read(_ options: HostClipboardReadOptions) async throws -> ClipboardReadResult {
        let gate = state.withLock { $0.gate }
        if let gate {
            await gate.wait()
        }
        if options.signal.isAborted { return .cancelled }
        return state.withLock { $0.nextReadResult }
    }

    func writeText(_ text: String, options: HostClipboardWriteOptions) async throws -> HostClipboardWriteResult {
        _ = text
        let gate = state.withLock { $0.gate }
        if let gate {
            await gate.wait()
        }
        if options.signal.isAborted { return .cancelled }
        return state.withLock { $0.nextWriteResult }
    }

    func clear(_ options: HostClipboardWriteOptions) async throws -> HostClipboardClearResult {
        let gate = state.withLock { $0.gate }
        if let gate {
            await gate.wait()
        }
        if options.signal.isAborted { return .cancelled }
        return state.withLock { $0.nextClearResult }
    }

    func dispose() async throws {
        state.withLock { $0.disposed = true }
    }
}

// MARK: - 1. WindowsDIBCodec Tests

@Suite("WindowsDIBCodec")
struct WindowsDIBCodecTests {
    @Test("RGBA <-> 32-bit bottom-up and top-down DIB round-trip preserves pixels and alpha")
    func rgbaToDibRoundTrip() throws {
        // 2x2 RGBA image with distinct channels and non-zero alpha
        let rgba: [UInt8] = [
            255, 0, 0, 255,       // (0, 0) red
            0, 255, 0, 128,       // (1, 0) semi-transparent green
            0, 0, 255, 255,       // (0, 1) blue
            200, 150, 100, 64,    // (1, 1) warm semi-transparent
        ]

        let bottomUpDib = try WindowsDIBCodec.rgbaToDib(rgba: rgba, width: 2, height: 2, topDown: false)
        #expect(bottomUpDib.count == 40 + 16)
        let decodedBottomUp = try WindowsDIBCodec.dibToRgba(bottomUpDib)
        #expect(decodedBottomUp.width == 2)
        #expect(decodedBottomUp.height == 2)
        #expect(decodedBottomUp.topDown == false)
        #expect(decodedBottomUp.hasAlpha == true)
        #expect(decodedBottomUp.rgba == rgba)

        let topDownDib = try WindowsDIBCodec.rgbaToDib(rgba: rgba, width: 2, height: 2, topDown: true)
        let decodedTopDown = try WindowsDIBCodec.dibToRgba(topDownDib)
        #expect(decodedTopDown.width == 2)
        #expect(decodedTopDown.height == 2)
        #expect(decodedTopDown.topDown == true)
        #expect(decodedTopDown.hasAlpha == true)
        #expect(decodedTopDown.rgba == rgba)
    }

    @Test("32-bit BI_RGB DIB with all-zero alpha bytes coerces to opaque alpha 255")
    func biRgbAllZeroAlphaCoercesToOpaque() throws {
        let zeroAlphaRgba: [UInt8] = [
            10, 20, 30, 0,
            40, 50, 60, 0,
        ]
        let dib = try WindowsDIBCodec.rgbaToDib(rgba: zeroAlphaRgba, width: 2, height: 1, topDown: true)
        let decoded = try WindowsDIBCodec.dibToRgba(dib)
        #expect(decoded.hasAlpha == false)
        #expect(decoded.rgba == [10, 20, 30, 255, 40, 50, 60, 255])
    }

    @Test("24-bit DIB with 4-byte row padding and BI_BITFIELDS 32-bit DIB decode accurately")
    func dib24BitAndBitfields() throws {
        // Build a 3x2 24-bit top-down DIB: 3 * 3 = 9 bytes per row -> padded to 12 bytes
        var dib24: [UInt8] = []
        func u16(_ v: UInt16) { dib24.append(UInt8(v & 0xFF)); dib24.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) {
            dib24.append(UInt8(v & 0xFF))
            dib24.append(UInt8((v >> 8) & 0xFF))
            dib24.append(UInt8((v >> 16) & 0xFF))
            dib24.append(UInt8((v >> 24) & 0xFF))
        }
        u32(40) // biSize
        u32(3) // biWidth
        u32(UInt32(bitPattern: Int32(-2))) // biHeight (top-down)
        u16(1) // biPlanes
        u16(24) // biBitCount
        u32(0) // BI_RGB
        u32(24) // biSizeImage
        u32(2835); u32(2835); u32(0); u32(0)

        // Row 0: BGR for (1,2,3), (4,5,6), (7,8,9) + 3 padding bytes
        dib24.append(contentsOf: [3, 2, 1, 6, 5, 4, 9, 8, 7, 0, 0, 0])
        // Row 1: BGR for (10,20,30), (40,50,60), (70,80,90) + 3 padding bytes
        dib24.append(contentsOf: [30, 20, 10, 60, 50, 40, 90, 80, 70, 0, 0, 0])

        let decoded24 = try WindowsDIBCodec.dibToRgba(dib24)
        #expect(decoded24.width == 3)
        #expect(decoded24.height == 2)
        #expect(decoded24.hasAlpha == false)
        #expect(decoded24.rgba == [
            1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255,
            10, 20, 30, 255, 40, 50, 60, 255, 70, 80, 90, 255,
        ])

        // 1x1 32-bit BI_BITFIELDS with 40-byte header + 12-byte RGB masks (R=0x000000FF, G=0x0000FF00, B=0x00FF0000)
        var dibBF: [UInt8] = []
        func bf16(_ v: UInt16) { dibBF.append(UInt8(v & 0xFF)); dibBF.append(UInt8(v >> 8)) }
        func bf32(_ v: UInt32) {
            dibBF.append(UInt8(v & 0xFF))
            dibBF.append(UInt8((v >> 8) & 0xFF))
            dibBF.append(UInt8((v >> 16) & 0xFF))
            dibBF.append(UInt8((v >> 24) & 0xFF))
        }
        bf32(40); bf32(1); bf32(1); bf16(1); bf16(32); bf32(3); bf32(4)
        bf32(0); bf32(0); bf32(0); bf32(0)
        // RGB masks
        bf32(0x0000_00FF)
        bf32(0x0000_FF00)
        bf32(0x00FF_0000)
        // Pixel bytes: R=12, G=34, B=56, X=0
        dibBF.append(contentsOf: [12, 34, 56, 0])

        let decodedBF = try WindowsDIBCodec.dibToRgba(dibBF)
        #expect(decodedBF.rgba == [12, 34, 56, 255])
    }

    @Test("BMP and PNG conversion round-trips cleanly through NativeImage")
    func bmpAndPngConversion() throws {
        let rgba: [UInt8] = [
            250, 10, 20, 255,
            30, 240, 40, 200,
        ]
        let bmp = try WindowsDIBCodec.rgbaToBmp(rgba: rgba, width: 2, height: 1)
        #expect(bmp[0] == UInt8(ascii: "B"))
        #expect(bmp[1] == UInt8(ascii: "M"))

        let decodedBmp = try WindowsDIBCodec.bmpToRgba(bmp)
        #expect(decodedBmp.rgba == rgba)

        let pngFromBmp = try WindowsDIBCodec.convertBmpToPng(bmp)
        #expect(Array(pngFromBmp.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        let decodedPng = try NativeImage.decode(pngFromBmp)
        #expect(decodedPng.width == 2)
        #expect(decodedPng.height == 1)
        let raw = try decodedPng.raw()
        #expect(raw.data == rgba)

        let dib = try WindowsDIBCodec.rgbaToDib(rgba: rgba, width: 2, height: 1)
        let pngFromDib = try WindowsDIBCodec.convertToPng(dib)
        #expect(pngFromDib == pngFromBmp)
    }

    @Test("WindowsDIBCodec enforces limits, cancellation, deadlines, and rejects malformed inputs")
    func dibErrorsAndLimits() throws {
        #expect(throws: WindowsDIBConvertError.invalidData) {
            _ = try WindowsDIBCodec.dibToRgba([1, 2, 3])
        }
        #expect(throws: WindowsDIBConvertError.invalidData) {
            _ = try WindowsDIBCodec.rgbaToDib(rgba: [1, 2, 3], width: 1, height: 1)
        }
        #expect(throws: WindowsDIBConvertError.invalidData) {
            _ = try WindowsDIBCodec.bmpToRgba([0x00, 0x00] + [UInt8](repeating: 0, count: 60))
        }

        let validDib = try WindowsDIBCodec.rgbaToDib(
            rgba: [UInt8](repeating: 255, count: 4 * 4 * 4),
            width: 4,
            height: 4
        )

        #expect(throws: WindowsDIBConvertError.limitExceeded) {
            _ = try WindowsDIBCodec.dibToRgba(validDib, options: WindowsDIBConvertOptions(maxImagePixels: 8))
        }
        #expect(throws: WindowsDIBConvertError.limitExceeded) {
            _ = try WindowsDIBCodec.dibToRgba(validDib, options: WindowsDIBConvertOptions(maxConversionBytes: 16))
        }
        #expect(throws: WindowsDIBConvertError.limitExceeded) {
            _ = try WindowsDIBCodec.convertToPng(validDib, options: WindowsDIBConvertOptions(maxOutputBytes: 16))
        }

        let controller = ClipboardAbortController()
        controller.abort(reason: "stop")
        #expect(throws: WindowsDIBConvertError.cancelled) {
            _ = try WindowsDIBCodec.dibToRgba(validDib, cancelSignal: controller.signal)
        }

        #expect(throws: WindowsDIBConvertError.timedOut) {
            _ = try WindowsDIBCodec.dibToRgba(validDib, options: WindowsDIBConvertOptions(deadlineNs: 0))
        }
    }
}

// MARK: - 2. WaylandWireProtocol & Linux Protocol Models Tests

@Suite("WaylandWireProtocol", .serialized)
struct WaylandWireProtocolTests {
    @Test("Wayland wire message encoding and decoding preserves headers, strings, arrays, and 32-bit alignment")
    func wireFramingRoundTrip() throws {
        let wire = try WaylandWireProtocol.encodeMessage(
            objectId: 42,
            opcode: 3,
            arguments: [
                .string("text/plain"),        // 10 + 1 NUL = 11 -> padded to 12 bytes (+4 len = 16)
                .uint32(0xDEAD_BEEF),         // 4 bytes
                .int32(-7),                   // 4 bytes
                .array([0xAA, 0xBB, 0xCC]),   // 3 bytes -> padded to 4 bytes (+4 len = 8)
                .fd(9),                       // out-of-band, 0 wire bytes
                .string(""),                  // 0 + 1 NUL = 1 -> padded to 4 bytes (+4 len = 8)
            ]
        )

        #expect(wire.count == 8 + 16 + 4 + 4 + 8 + 8)
        #expect(wire.count % 4 == 0)

        let header = try WaylandWireProtocol.decodeHeader(wire)
        #expect(header == WaylandWireHeader(objectId: 42, opcode: 3, length: UInt16(wire.count)))

        let (mime, off1) = try WaylandWireProtocol.decodeString(wire, offset: WaylandWireProtocol.headerSize)
        #expect(mime == "text/plain")
        #expect(off1 == 8 + 16)

        // Skip uint32 + int32 (8 bytes)
        let (arr, off2) = try WaylandWireProtocol.decodeArray(wire, offset: off1 + 8)
        #expect(arr == [0xAA, 0xBB, 0xCC])
        #expect(off2 == off1 + 8 + 8)

        let (emptyStr, off3) = try WaylandWireProtocol.decodeString(wire, offset: off2)
        #expect(emptyStr == "")
        #expect(off3 == wire.count)
    }

    @Test("WaylandWireProtocol rejects truncated headers, unaligned lengths, and invalid UTF-8 strings")
    func wireFramingErrors() {
        #expect(throws: WaylandWireError.truncatedHeader) {
            _ = try WaylandWireProtocol.decodeHeader([1, 2, 3, 4])
        }

        // Length = 9 (unaligned, not multiple of 4)
        let badLenHeader: [UInt8] = [1, 0, 0, 0, 0, 0, 9, 0]
        #expect(throws: WaylandWireError.invalidLength) {
            _ = try WaylandWireProtocol.decodeHeader(badLenHeader)
        }

        // Invalid UTF-8 bytes in string payload with NUL terminator
        let badUtf8: [UInt8] = [3, 0, 0, 0, 0xFF, 0xFE, 0x00, 0x00]
        #expect(throws: WaylandWireError.invalidStringEncoding) {
            _ = try WaylandWireProtocol.decodeString(badUtf8, offset: 0)
        }

        // Missing trailing NUL byte
        let missingNul: [UInt8] = [2, 0, 0, 0, 0x41, 0x42, 0x00, 0x00]
        #expect(throws: WaylandWireError.invalidStringEncoding) {
            _ = try WaylandWireProtocol.decodeString(missingNul, offset: 0)
        }

        // Truncated array payload
        let truncArr: [UInt8] = [16, 0, 0, 0, 1, 2, 3, 4]
        #expect(throws: WaylandWireError.truncatedPayload) {
            _ = try WaylandWireProtocol.decodeArray(truncArr, offset: 0)
        }
    }

    @Test("Wayland data-control metadata, canonical MIME essence, and offer matching")
    func waylandMetadataAndOfferMatching() {
        let ext = WaylandDataControlMetadata(kind: .ext)
        #expect(ext.manager.name == "ext_data_control_manager_v1")
        #expect(ext.manager.version == 1)
        #expect(ext.device.requests.last?.signature == "?o")

        let wlr = WaylandDataControlMetadata(kind: .wlr)
        #expect(wlr.manager.name == "zwlr_data_control_manager_v1")
        #expect(wlr.manager.version == 2)
        #expect(wlr.device.requests.last?.signature == "2?o")

        #expect(canonicalWaylandMimeEssence("TEXT/PLAIN; charset=utf-8") == "text/plain")
        #expect(canonicalWaylandMimeEssence("  text/plain ; charset=\"UTF-8\" ") == "text/plain")
        #expect(canonicalWaylandMimeEssence("text/plain; charset=iso-8859-1") == nil)
        #expect(canonicalWaylandMimeEssence("IMAGE/PNG") == "image/png")
        #expect(canonicalWaylandMimeEssence("application/octet-stream") == nil)

        let offer = WaylandClipboardOffer(objectId: 7, mimeTypes: ["image/bmp", "text/plain;charset=utf-8"])
        let pngMatch = offer.bestMatch(preferredTypes: ["image/png", "text/plain"])
        #expect(pngMatch == WaylandClipboardMimeMatch(requestedMime: "image/png", offeredMime: "image/bmp", needsBmpToPng: true))

        let textMatch = offer.bestMatch(preferredTypes: ["text/plain"])
        #expect(textMatch == WaylandClipboardMimeMatch(requestedMime: "text/plain", offeredMime: "text/plain;charset=utf-8", needsBmpToPng: false))

        let conn = WaylandClipboardConnection.testReadyConnection(seatName: "seat1")
        #expect(conn.isReady)
        #expect(conn.seatName == "seat1")
        conn.setOffer(offer, selection: .primary)
        #expect(conn.offer(for: .primary) == offer)
        #expect(conn.offer(for: .clipboard) == nil)
    }

    @Test("LinuxClipboardRuntime environment selection, bounded messages, and symbol swap")
    func linuxClipboardRuntimeDiagnostics() {
        let prevSymbols = LinuxClipboardRuntime.testSwapWaylandSymbols(LinuxWaylandSymbols(available: true))
        defer {
            _ = LinuxClipboardRuntime.testSwapWaylandSymbols(prevSymbols)
            LinuxClipboardRuntime.clearCause()
        }

        #expect(LinuxClipboardRuntime.waylandSymbols().available == true)

        let waylandEnv = LinuxClipboardEnvironment(waylandDisplay: "wayland-0", display: ":0", xdgRuntimeDir: "/tmp", waylandSeat: "seat0")
        #expect(waylandEnv.preferredMechanism == .wayland)
        #expect(LinuxClipboardRuntime.initialize(environment: waylandEnv).mechanism == .wayland)

        let x11Env = LinuxClipboardEnvironment(waylandDisplay: nil, display: ":0", xdgRuntimeDir: nil)
        #expect(x11Env.preferredMechanism == .x11)

        let headlessEnv = LinuxClipboardEnvironment(waylandDisplay: nil, display: nil, xdgRuntimeDir: nil)
        let report = LinuxClipboardRuntime.initialize(environment: headlessEnv)
        #expect(report.mechanism == .unavailable)
        #expect(LinuxClipboardRuntime.testCauseReport() == report.cause)

        let longMsg = String(repeating: "a", count: 400)
        #expect(LinuxClipboardRuntime.bounded(longMsg, maxBytes: 32).utf8.count == 32)
    }
}

// MARK: - 3. ClipboardSyncLatch, ClipboardSyncMutex & ClipboardMonotonicClock Tests

@Suite("PlatformClipboardSync")
struct PlatformClipboardSyncTests {
    @Test("ClipboardMonotonicClock advances monotonically across sleep")
    func monotonicClockAndSleep() {
        ClipboardMonotonicClock.initialize()
        let t0 = ClipboardMonotonicClock.nowNanoseconds()
        ClipboardMonotonicClock.sleep(nanoseconds: 2_000_000) // 2ms
        let t1 = ClipboardSync.nowNanoseconds()
        #expect(t1 >= t0)
        #expect(t1 - t0 >= 500_000) // at least 0.5ms elapsed
    }

    @Test("ClipboardSyncMutex isolates mutations and rethrows errors")
    func syncMutexBehavior() {
        let mutex = ClipboardSyncMutex()
        let result = mutex.withLock { 21 * 2 }
        #expect(result == 42)

        enum TestErr: Error { case boom }
        #expect(throws: TestErr.self) {
            try mutex.withLock { throw TestErr.boom }
        }
    }

    @Test("ClipboardSyncLatch supports signal, reset, generation tracking, async wait, and timeout")
    func syncLatchBehavior() async {
        let latch = ClipboardSyncLatch()
        #expect(latch.isSignaled == false)
        #expect(latch.generation == 0)

        let immediateTimeout = await latch.wait(timeoutNanoseconds: 0)
        #expect(immediateTimeout == false)

        let shortTimeout = await latch.wait(timeoutNanoseconds: 3_000_000) // 3ms
        #expect(shortTimeout == false)

        let signaller = Task {
            try? await Task.sleep(nanoseconds: 3_000_000)
            latch.signal()
        }
        await latch.wait()
        await signaller.value

        #expect(latch.isSignaled == true)
        #expect(latch.generation == 1)

        // Already signaled returns immediately even with UInt64.max timeout
        let alreadySignaled = await latch.wait(timeoutNanoseconds: UInt64.max)
        #expect(alreadySignaled == true)

        latch.reset()
        #expect(latch.isSignaled == false)

        let wakeTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000)
            latch.signal()
        }
        let woke = await latch.wait(timeoutNanoseconds: 500_000_000)
        await wakeTask.value
        #expect(woke == true)
        #expect(latch.generation == 2)
    }
}

// MARK: - 4. PosixClipboardIO & Registry Installation / Fallback Tests

@Suite("PlatformClipboardIOAndRegistry", .serialized)
struct PlatformClipboardIOAndRegistryTests {
    #if os(macOS) || os(Linux) || os(FreeBSD)
    @Test("PosixClipboardIO pipe, write, readAll, dup, fcntl, stat, and runProcess round-trip")
    func posixPipeAndProcessIO() throws {
        let (readFD, writeFD) = try PosixClipboardIO.pipe()
        var closedRead = false
        var closedWrite = false
        defer {
            if !closedRead { PosixClipboardIO.close(readFD) }
            if !closedWrite { PosixClipboardIO.close(writeFD) }
        }

        let dupWrite = try PosixClipboardIO.duplicate(writeFD)
        let payload = Array("swift-opentui-clipboard-pipe".utf8)
        let written = try PosixClipboardIO.write(fd: dupWrite, bytes: payload)
        #expect(written == payload.count)
        PosixClipboardIO.close(dupWrite)
        PosixClipboardIO.close(writeFD)
        closedWrite = true

        // Check fcntl get/set flags round-trip on readFD
        let flags = try PosixClipboardIO.getFlags(readFD)
        try PosixClipboardIO.setFlags(readFD, flags: flags)

        let readRes = try PosixClipboardIO.readAll(fd: readFD, maxBytes: 1024)
        #expect(readRes.exceeded == false)
        #expect(readRes.bytes == payload)
        PosixClipboardIO.close(readFD)
        closedRead = true

        // Overflow detection on readAll
        let (r2, w2) = try PosixClipboardIO.pipe()
        defer { PosixClipboardIO.close(r2) }
        _ = try PosixClipboardIO.write(fd: w2, bytes: Array("0123456789".utf8))
        PosixClipboardIO.close(w2)
        let limited = try PosixClipboardIO.readAll(fd: r2, maxBytes: 4)
        #expect(limited.exceeded == true)

        // stat on root directory succeeds and is not a socket
        let rootStat = try PosixClipboardIO.stat(path: "/")
        #expect(rootStat.isSocket == false)

        // stat on nonexistent path throws systemError
        #expect(throws: PosixClipboardIOError.self) {
            _ = try PosixClipboardIO.stat(path: "/nonexistent-opentui-clipboard-test-path")
        }

        // getEnv returns nil for missing variable
        #expect(PosixClipboardIO.getEnv("OPENTUI_DEFINITELY_UNSET_ENV_VAR_987654") == nil)

        // runProcess with /bin/cat echoes stdin cleanly without touching clipboard
        let catPayload = Array("hello-from-posix-spawn".utf8)
        let proc = try PosixClipboardIO.runProcess(
            executablePath: "/bin/cat",
            arguments: [],
            stdinBytes: catPayload,
            maxOutputBytes: 1024
        )
        #expect(proc.exitCode == 0)
        #expect(proc.exceededOutputLimit == false)
        #expect(proc.stdout == catPayload)
    }
    #endif

    @Test("installPlatformHostClipboard / uninstallPlatformHostClipboard register and fall back cleanly")
    func registryRegistrationAndFallback() async throws {
        let previousFactory = NativeHostClipboardBackendRegistry.currentFactory()
        defer { NativeHostClipboardBackendRegistry.register(previousFactory) }

        // Install an injected in-memory backend factory (never touches the real OS clipboard)
        let sharedMemory = InMemoryHostClipboardBackend()
        installPlatformHostClipboard { _ in sharedMemory }
        #expect(NativeHostClipboardBackendRegistry.currentFactory() != nil)

        let service = try createHostClipboard(HostClipboardOptions(timeoutMs: 500))
        let writeRes = try await service.writeText("injected-backend-value")
        #expect(writeRes == .written)

        let readRes = try await service.read(ClipboardReadOptions(preferredTypes: ["text/plain"]))
        #expect(readRes == .read(ClipboardRepresentation(mimeType: "text/plain", bytes: Array("injected-backend-value".utf8))))
        try await service.dispose()

        // Uninstall restores default pure-Swift InMemoryHostClipboardBackend fallback
        uninstallPlatformHostClipboard()
        #expect(NativeHostClipboardBackendRegistry.currentFactory() == nil)

        let fallbackBackend = try createNativeHostClipboardBackend(NormalizedHostClipboardOptions())
        #expect(fallbackBackend is InMemoryHostClipboardBackend)
    }

    #if os(macOS)
    @Test("MacOSHostClipboardBackend delegates through injected executor without mutating OS pasteboard")
    func macOSBackendWithInjectedExecutor() async throws {
        let storage = Mutex<[UInt8]?>(nil)
        let backend = MacOSHostClipboardBackend { job, options in
            if options.signal?.isAborted == true {
                return MacOSClipboardResult(status: .cancelled)
            }
            switch job {
            case .writeText(let w):
                storage.withLock { $0 = Array(w.text.utf8) }
                return MacOSClipboardResult(status: .written)
            case .clear:
                storage.withLock { $0 = nil }
                return MacOSClipboardResult(status: .cleared)
            case .read(let r):
                guard let data = storage.withLock({ $0 }) else {
                    return MacOSClipboardResult(status: .empty)
                }
                if data.count > r.maxBytes {
                    return MacOSClipboardResult(status: .limitExceeded)
                }
                return MacOSClipboardResult(
                    status: .read,
                    readResult: MacOSClipboardReadResult(mimeType: "text/plain", bytes: data)
                )
            }
        }

        let signal = ClipboardAbortController().signal
        // Primary selection is unsupported on macOS
        let primaryWrite = try await backend.writeText(
            "ignored",
            options: HostClipboardWriteOptions(selection: .primary, timeoutMs: 500, signal: signal)
        )
        #expect(primaryWrite == .unsupported)

        let written = try await backend.writeText(
            "mac-mock-text",
            options: HostClipboardWriteOptions(selection: .clipboard, timeoutMs: 500, signal: signal)
        )
        #expect(written == .written)

        let readOk = try await backend.read(
            HostClipboardReadOptions(preferredTypes: ["text/plain"], selection: .clipboard, maxBytes: 128, timeoutMs: 500, signal: signal)
        )
        #expect(readOk == .read(ClipboardRepresentation(mimeType: "text/plain", bytes: Array("mac-mock-text".utf8))))

        let readTooLarge = try await backend.read(
            HostClipboardReadOptions(preferredTypes: ["text/plain"], selection: .clipboard, maxBytes: 4, timeoutMs: 500, signal: signal)
        )
        #expect(readTooLarge == .limitExceeded)

        let cleared = try await backend.clear(
            HostClipboardWriteOptions(selection: .clipboard, timeoutMs: 500, signal: signal)
        )
        #expect(cleared == .cleared)

        let readEmpty = try await backend.read(
            HostClipboardReadOptions(preferredTypes: ["text/plain"], selection: .clipboard, maxBytes: 128, timeoutMs: 500, signal: signal)
        )
        #expect(readEmpty == .empty)

        try await backend.dispose()
        await #expect(throws: HostClipboardError.disposed("MacOSHostClipboardBackend is disposed")) {
            _ = try await backend.clear(HostClipboardWriteOptions(selection: .clipboard, timeoutMs: 500, signal: signal))
        }
    }
    #endif
}

// MARK: - 5. HostClipboardNativeABI Operations Tests

@Suite("PlatformClipboardABI")
struct PlatformClipboardABITests {
    @Test("HostClipboardNativeABI full write/read/copy/clear/shutdown/destroy lifecycle with in-memory backend")
    func abiFullLifecycle() async {
        let store = InMemoryHostClipboardBackend()
        let abi = HostClipboardNativeABI { _ in store }
        let ctx: UInt64 = 1001

        #expect(abi.ot_clipboard_service_create(contextId: ctx, maxOperations: 2, maxProviderTransfers: 2) == 0)
        // Duplicate contextId fails
        #expect(abi.ot_clipboard_service_create(contextId: ctx) == -1)

        // Write text via C-ABI surface
        var writeHandle = HostClipboardHandle.invalid
        let writeStart = abi.ot_clipboard_write_operation_start(
            contextId: ctx,
            text: "abi-clipboard-payload",
            selection: 0,
            outOperation: &writeHandle
        )
        #expect(writeStart == HostClipboardStartStatus.ok.rawValue)
        #expect(abi.ot_clipboard_operation_poll(writeHandle) == HostClipboardOperationStatus.written.rawValue)
        #expect(abi.ot_clipboard_operation_destroy(writeHandle) == HostClipboardDestroyStatus.destroyed.rawValue)

        // Read back via C-ABI surface
        var readHandle = HostClipboardHandle.invalid
        let readStart = abi.ot_clipboard_read_operation_start(
            contextId: ctx,
            preferredTypes: ["text/plain"],
            selection: 0,
            maxBytes: 1024,
            outOperation: &readHandle
        )
        #expect(readStart == HostClipboardStartStatus.ok.rawValue)
        #expect(abi.ot_clipboard_operation_poll(readHandle) == HostClipboardOperationStatus.read.rawValue)

        var mimeLen: UInt32 = 0
        #expect(abi.ot_clipboard_operation_result_mime_length(readHandle, outLength: &mimeLen) == HostClipboardCopyStatus.ok.rawValue)
        #expect(mimeLen == UInt32("text/plain".utf8.count))

        var copiedMime: [UInt8] = []
        #expect(
            abi.ot_clipboard_operation_result_mime_copy(readHandle, capacity: 2, outBytes: &copiedMime)
                == HostClipboardCopyStatus.bufferTooSmall.rawValue
        )
        #expect(
            abi.ot_clipboard_operation_result_mime_copy(readHandle, capacity: Int(mimeLen), outBytes: &copiedMime)
                == HostClipboardCopyStatus.ok.rawValue
        )
        #expect(String(decoding: copiedMime, as: UTF8.self) == "text/plain")

        var dataLen: UInt32 = 0
        #expect(abi.ot_clipboard_operation_result_data_length(readHandle, outLength: &dataLen) == HostClipboardCopyStatus.ok.rawValue)
        #expect(dataLen == UInt32("abi-clipboard-payload".utf8.count))

        var copiedData: [UInt8] = []
        #expect(
            abi.ot_clipboard_operation_result_data_copy(readHandle, capacity: 4, outBytes: &copiedData)
                == HostClipboardCopyStatus.bufferTooSmall.rawValue
        )
        #expect(
            abi.ot_clipboard_operation_result_data_copy(readHandle, capacity: Int(dataLen), outBytes: &copiedData)
                == HostClipboardCopyStatus.ok.rawValue
        )
        #expect(String(decoding: copiedData, as: UTF8.self) == "abi-clipboard-payload")
        #expect(abi.ot_clipboard_operation_destroy(readHandle) == HostClipboardDestroyStatus.destroyed.rawValue)

        // Read with maxBytes smaller than payload -> limitExceeded
        var smallReadHandle = HostClipboardHandle.invalid
        _ = abi.ot_clipboard_read_operation_start(
            contextId: ctx,
            preferredTypes: ["text/plain"],
            selection: 0,
            maxBytes: 4,
            outOperation: &smallReadHandle
        )
        #expect(abi.ot_clipboard_operation_poll(smallReadHandle) == HostClipboardOperationStatus.limitExceeded.rawValue)
        #expect(abi.ot_clipboard_operation_destroy(smallReadHandle) == HostClipboardDestroyStatus.destroyed.rawValue)

        // Clear via async ABI operation and poll until terminal
        var clearHandle = HostClipboardHandle.invalid
        let clearStart = abi.ot_clipboard_clear_operation_start(contextId: ctx, selection: 0, outOperation: &clearHandle)
        #expect(clearStart == HostClipboardStartStatus.ok.rawValue)
        var clearStatus = abi.ot_clipboard_operation_poll(clearHandle)
        for _ in 0..<200 where clearStatus == HostClipboardOperationStatus.pending.rawValue {
            try? await Task.sleep(nanoseconds: 1_000_000)
            clearStatus = abi.ot_clipboard_operation_poll(clearHandle)
        }
        #expect(clearStatus == HostClipboardOperationStatus.cleared.rawValue)
        #expect(abi.ot_clipboard_operation_destroy(clearHandle) == HostClipboardDestroyStatus.destroyed.rawValue)

        // Subsequent read reports empty
        var emptyHandle = HostClipboardHandle.invalid
        _ = abi.ot_clipboard_read_operation_start(
            contextId: ctx,
            preferredTypes: ["text/plain"],
            selection: 0,
            maxBytes: 1024,
            outOperation: &emptyHandle
        )
        #expect(abi.ot_clipboard_operation_poll(emptyHandle) == HostClipboardOperationStatus.empty.rawValue)
        #expect(abi.ot_clipboard_operation_destroy(emptyHandle) == HostClipboardDestroyStatus.destroyed.rawValue)

        // Shutdown and destroy service cleanly
        #expect(abi.ot_clipboard_service_begin_shutdown(contextId: ctx) == HostClipboardShutdownStatus.ready.rawValue)
        #expect(abi.ot_clipboard_service_poll_shutdown(contextId: ctx) == HostClipboardShutdownStatus.ready.rawValue)
        #expect(abi.ot_clipboard_service_destroy(contextId: ctx) == HostClipboardDestroyStatus.destroyed.rawValue)
        #expect(abi.ot_clipboard_service_destroy(contextId: ctx) == HostClipboardDestroyStatus.invalidHandle.rawValue)
    }

    @Test("HostClipboardNativeABI handles pending cancellation, concurrency limits, and failure diagnostics")
    func abiCancellationLimitsAndDiagnostics() async {
        let controlled = ControlledHostClipboardBackend()
        let gate = ClipboardSyncLatch()
        controlled.setGate(gate)

        let abi = HostClipboardNativeABI { _ in controlled }
        let ctx: UInt64 = 2002
        #expect(abi.ot_clipboard_service_create(contextId: ctx, maxOperations: 1) == 0)

        // Start a gated read that stays pending until cancelled or released
        var pendingHandle = HostClipboardHandle.invalid
        let start1 = abi.ot_clipboard_read_operation_start(
            contextId: ctx,
            preferredTypes: ["text/plain"],
            selection: 0,
            maxBytes: 1024,
            outOperation: &pendingHandle
        )
        #expect(start1 == HostClipboardStartStatus.ok.rawValue)
        #expect(abi.ot_clipboard_operation_poll(pendingHandle) == HostClipboardOperationStatus.pending.rawValue)

        // Cannot destroy a pending operation
        #expect(abi.ot_clipboard_operation_destroy(pendingHandle) == HostClipboardDestroyStatus.notReady.rawValue)

        // Second concurrent operation hits maxOperations = 1 -> limitExceeded
        var secondHandle = HostClipboardHandle.invalid
        let start2 = abi.ot_clipboard_read_operation_start(
            contextId: ctx,
            preferredTypes: ["text/plain"],
            selection: 0,
            maxBytes: 1024,
            outOperation: &secondHandle
        )
        #expect(start2 == HostClipboardStartStatus.limitExceeded.rawValue)

        // Cancel pending operation -> requested, then alreadyTerminal on second cancel
        #expect(abi.ot_clipboard_operation_cancel(pendingHandle) == HostClipboardCancelStatus.requested.rawValue)
        #expect(abi.ot_clipboard_operation_cancel(pendingHandle) == HostClipboardCancelStatus.alreadyTerminal.rawValue)
        #expect(abi.ot_clipboard_operation_poll(pendingHandle) == HostClipboardOperationStatus.cancelled.rawValue)
        gate.signal()
        #expect(abi.ot_clipboard_operation_destroy(pendingHandle) == HostClipboardDestroyStatus.destroyed.rawValue)

        // Configure failure with error code and diagnostic message
        controlled.setGate(nil)
        controlled.setNextRead(.failed(ClipboardFailure(message: "synthetic-backend-error", code: 77)))

        var failHandle = HostClipboardHandle.invalid
        _ = abi.ot_clipboard_read_operation_start(
            contextId: ctx,
            preferredTypes: ["text/plain"],
            selection: 0,
            maxBytes: 1024,
            outOperation: &failHandle
        )
        var failStatus = abi.ot_clipboard_operation_poll(failHandle)
        for _ in 0..<200 where failStatus == HostClipboardOperationStatus.pending.rawValue {
            try? await Task.sleep(nanoseconds: 1_000_000)
            failStatus = abi.ot_clipboard_operation_poll(failHandle)
        }
        #expect(failStatus == HostClipboardOperationStatus.failed.rawValue)

        var errCode: UInt32 = 0
        #expect(abi.ot_clipboard_operation_result_error_code(failHandle, outCode: &errCode) == HostClipboardCopyStatus.ok.rawValue)
        #expect(errCode == 77)

        var diagLen: UInt32 = 0
        #expect(abi.ot_clipboard_operation_result_diagnostic_length(failHandle, outLength: &diagLen) == HostClipboardCopyStatus.ok.rawValue)
        var diagBytes: [UInt8] = []
        #expect(
            abi.ot_clipboard_operation_result_diagnostic_copy(failHandle, capacity: Int(diagLen), outBytes: &diagBytes)
                == HostClipboardCopyStatus.ok.rawValue
        )
        #expect(String(decoding: diagBytes, as: UTF8.self) == "synthetic-backend-error")

        // Drain clears remaining operations so destroy succeeds
        #expect(abi.ot_clipboard_service_drain(contextId: ctx) == 0)
        #expect(abi.ot_clipboard_service_destroy(contextId: ctx) == HostClipboardDestroyStatus.destroyed.rawValue)
    }
}

#if !os(WASI)
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import OpenCodePlatform

/// Foundation & POSIX filesystem helpers kept separate from `import Testing`
/// to obey the macOS Command Line Tools cross-import rule.
enum NativeFileWatcherHelper {
    static func makeTempDirectory(prefix: String = "opencode-native-watcher") throws -> String {
        #if os(WASI)
        return "/tmp/\(prefix)-\(UInt64.random(in: 1...UInt64.max))"
        #else
        let base = NSTemporaryDirectory()
        let name = "\(prefix)-\(UUID().uuidString)"
        let path = (base as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
        #endif
    }

    static func removeItemIfExists(at path: String) {
        #if !os(WASI)
        try? FileManager.default.removeItem(atPath: path)
        #endif
    }

    static func createDirectory(at path: String) throws {
        #if !os(WASI)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #endif
    }

    /// Creates or overwrites a file directly in place (without atomic temp-file swap)
    /// so create vs in-place modify OS events are preserved cleanly.
    static func writeFileInPlace(_ text: String, to path: String) throws {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let bytes = Array(text.utf8)
        let fd: Int32
        #if canImport(Darwin)
        fd = Darwin.open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
        #elseif canImport(Glibc)
        fd = Glibc.open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
        #else
        fd = Musl.open(path, O_WRONLY | O_CREAT | O_TRUNC, mode_t(0o644))
        #endif
        guard fd >= 0 else {
            throw PlatformError.ioFailure("open failed for '\(path)' (errno=\(errno))")
        }
        defer {
            #if canImport(Darwin)
            _ = Darwin.close(fd)
            #elseif canImport(Glibc)
            _ = Glibc.close(fd)
            #else
            _ = Musl.close(fd)
            #endif
        }
        var written = 0
        while written < bytes.count {
            let n: Int = bytes.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return -1 }
                #if canImport(Darwin)
                return Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                #elseif canImport(Glibc)
                return Glibc.write(fd, base.advanced(by: written), bytes.count - written)
                #else
                return Musl.write(fd, base.advanced(by: written), bytes.count - written)
                #endif
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw PlatformError.ioFailure("write failed for '\(path)' (errno=\(errno))")
            }
            written += n
        }
        #elseif !os(WASI)
        let data = Data(text.utf8)
        try data.write(to: URL(fileURLWithPath: path), options: [])
        #endif
    }

    static func renameItem(from source: String, to destination: String) throws {
        #if canImport(Darwin)
        guard Darwin.rename(source, destination) == 0 else {
            throw PlatformError.ioFailure("rename failed '\(source)' -> '\(destination)' (errno=\(errno))")
        }
        #elseif canImport(Glibc)
        guard Glibc.rename(source, destination) == 0 else {
            throw PlatformError.ioFailure("rename failed '\(source)' -> '\(destination)' (errno=\(errno))")
        }
        #elseif canImport(Musl)
        guard Musl.rename(source, destination) == 0 else {
            throw PlatformError.ioFailure("rename failed '\(source)' -> '\(destination)' (errno=\(errno))")
        }
        #elseif !os(WASI)
        try FileManager.default.moveItem(atPath: source, toPath: destination)
        #endif
    }

    static func deleteFile(at path: String) throws {
        #if canImport(Darwin)
        guard Darwin.unlink(path) == 0 else {
            throw PlatformError.ioFailure("unlink failed for '\(path)' (errno=\(errno))")
        }
        #elseif canImport(Glibc)
        guard Glibc.unlink(path) == 0 else {
            throw PlatformError.ioFailure("unlink failed for '\(path)' (errno=\(errno))")
        }
        #elseif canImport(Musl)
        guard Musl.unlink(path) == 0 else {
            throw PlatformError.ioFailure("unlink failed for '\(path)' (errno=\(errno))")
        }
        #elseif !os(WASI)
        try FileManager.default.removeItem(atPath: path)
        #endif
    }
}

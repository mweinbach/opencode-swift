/// How the app shows a file, derived from its extension.
// parity: util/src/artifact.ts#ArtifactKind [status=implemented hash=ac9415b0756e]
public enum ArtifactKind: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case image
    case svg
    case audio
    case video
    case pdf
    case html
    case markdown
    case mermaid
    case table
    case font
    case document
    case spreadsheet
    case presentation
    case text
}

private let artifactOfficeKinds: [String: ArtifactKind] = [
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document": .document,
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": .spreadsheet,
    "application/vnd.openxmlformats-officedocument.presentationml.presentation": .presentation,
]

private let artifactMimes: [String: String] = [
    "png": "image/png",
    "jpg": "image/jpeg",
    "jpeg": "image/jpeg",
    "gif": "image/gif",
    "webp": "image/webp",
    "avif": "image/avif",
    "bmp": "image/bmp",
    "ico": "image/x-icon",
    "tif": "image/tiff",
    "tiff": "image/tiff",
    "heic": "image/heic",
    "svg": "image/svg+xml",
    "mp3": "audio/mpeg",
    "wav": "audio/wav",
    "ogg": "audio/ogg",
    "oga": "audio/ogg",
    "m4a": "audio/mp4",
    "aac": "audio/aac",
    "flac": "audio/flac",
    "opus": "audio/ogg",
    "weba": "audio/webm",
    "mp4": "video/mp4",
    "m4v": "video/mp4",
    "webm": "video/webm",
    "mov": "video/quicktime",
    "ogv": "video/ogg",
    "mkv": "video/x-matroska",
    "pdf": "application/pdf",
    "html": "text/html",
    "htm": "text/html",
    "md": "text/markdown",
    "markdown": "text/markdown",
    "mdx": "text/markdown",
    "mmd": "text/vnd.mermaid",
    "mermaid": "text/vnd.mermaid",
    "csv": "text/csv",
    "tsv": "text/tab-separated-values",
    "ttf": "font/ttf",
    "otf": "font/otf",
    "woff": "font/woff",
    "woff2": "font/woff2",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
]

private func artifactExtension(_ path: String) -> String {
    let units = Array(path.utf16)
    var nameStart = 0
    for idx in stride(from: units.count - 1, through: 0, by: -1) {
        if units[idx] == 0x2F || units[idx] == 0x5C { // '/' or '\'
            nameStart = idx + 1
            break
        }
    }
    var lastDot = -1
    if nameStart < units.count {
        for idx in stride(from: units.count - 1, through: nameStart, by: -1) {
            if units[idx] == 0x2E { // '.'
                lastDot = idx - nameStart
                break
            }
        }
    }
    if lastDot <= 0 {
        return ""
    }
    let extUnits = units[(nameStart + lastDot + 1)...]
    return String(decoding: extUnits, as: UTF16.self).lowercased()
}

/// Returns the MIME type for a known artifact file extension, or `nil` if unrecognized.
// parity: util/src/artifact.ts#artifactMime [status=implemented hash=b045b83177aa]
public func artifactMime(_ path: String) -> String? {
    artifactMimes[artifactExtension(path)]
}

/// Maps a file path to its display `ArtifactKind`, defaulting to `.text`.
// parity: util/src/artifact.ts#artifactKind [status=implemented hash=c61eac57be79]
public func artifactKind(_ path: String) -> ArtifactKind {
    guard let mime = artifactMime(path) else { return .text }
    if mime == "image/svg+xml" { return .svg }
    if mime == "application/pdf" { return .pdf }
    if mime == "text/html" { return .html }
    if mime == "text/markdown" { return .markdown }
    if mime == "text/vnd.mermaid" { return .mermaid }
    if mime == "text/csv" || mime == "text/tab-separated-values" { return .table }
    if mime.hasPrefix("image/") { return .image }
    if mime.hasPrefix("audio/") { return .audio }
    if mime.hasPrefix("font/") { return .font }
    return artifactOfficeKinds[mime] ?? .video
}

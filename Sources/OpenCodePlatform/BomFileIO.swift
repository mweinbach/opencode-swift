import OpenCodeUtil

/// File-backed BOM helpers matching `util/src/bom.ts#readFile` and `syncFile`.
public enum BomFileIO {
    // parity: util/src/bom.ts#readFile [status=implemented hash=47ed372886c6]
    public static func readFile(
        fs: any OpenCodeFileSystem,
        filepath: String
    ) async throws -> BomSplitResult {
        Bom.decodeBytes(try await fs.readFile(at: filepath))
    }

    // parity: util/src/bom.ts#syncFile [status=implemented hash=41fee28053c4]
    public static func syncFile(
        fs: any OpenCodeFileSystem,
        filepath: String,
        bom: Bool
    ) async throws -> String {
        let synced = Bom.syncBytes(try await fs.readFile(at: filepath), bom: bom)
        if let bytes = synced.bytes {
            try await fs.writeFile(bytes, to: filepath, createDirectories: true)
        }
        return synced.text
    }
}

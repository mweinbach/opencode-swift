/// The XML envelope every background completion notice uses, so the model can tell harness input apart from the
/// user. Ports `packages/core/src/session/background-result.ts`.
public enum CoreSessionBackgroundResult {
    /// Wraps `body` as `<background-result {attributes}>…</background-result>`.
    // parity: core/src/session/background-result.ts#render [status=implemented hash=45bf322855b7]
    public static func render(_ attributes: String, _ body: String) -> String {
        "<background-result \(attributes)>\n\(body)\n</background-result>"
    }
}

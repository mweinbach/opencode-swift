// High-level LaTeX parsing + 2D terminal rendering entrypoints (`packages/latex/src/render.ts`).

/// Parses `source` into a `MathNode` AST and lays it out onto a 2D Unicode `MathLayout`.
// parity: latex/src/render.ts#renderLatex [status=implemented hash=16001854ab73]
public func renderLatex(_ source: String, options: RenderLatexOptions = RenderLatexOptions()) throws -> MathLayout {
    layoutMath(try parseLatex(source, options: options.parseOptions), options: options)
}

/// Parses `source`, lays it out onto a 2D grid, and serializes the rendered math to a Unicode string.
// parity: latex/src/render.ts#renderLatexToString [status=implemented hash=8ce27897b786]
public func renderLatexToString(_ source: String, options: RenderLatexOptions = RenderLatexOptions()) throws -> String {
    try renderLatex(source, options: options).toString()
}

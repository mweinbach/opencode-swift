// Built-in TUI LaTeX math rendering plugin descriptor (`packages/latex/src/plugin.ts`).

import OpenCodeCore
import OpenCodeSchema
import OpenCodeUtil
import OpenTUICore
import OpenTUIRenderables

private func makeLatexPluginRenderNode(_ source: String) -> PluginTui.RenderNode {
    do {
        let layout = try renderLatex(
            source,
            options: RenderLatexOptions(strict: true, displayMode: true)
        )
        let props: [String: JSONValue] = [
            "width": JSONValue.int(Int64(layout.width)),
            "height": JSONValue.int(Int64(layout.height)),
            "baseline": JSONValue.int(Int64(layout.baseline)),
            "source": JSONValue.string(source),
        ]
        return PluginTui.RenderNode(
            kind: "latex",
            text: layout.toString(),
            props: props
        )
    } catch {
        let props: [String: JSONValue] = [
            "fallback": JSONValue.bool(true),
        ]
        return PluginTui.RenderNode(
            kind: "code",
            text: source,
            props: props
        )
    }
}

private func setupLatexPlugin(_ context: PluginTui.Context) async throws -> PluginTui.Cleanup? {
    let renderNode: @Sendable (String) -> PluginTui.RenderNode = { source in
        makeLatexPluginRenderNode(source)
    }
    let disposeLatex = context.registerCodeBlockRenderer("latex", renderNode)
    let disposeMath = context.registerCodeBlockRenderer("math", renderNode)
    return {
        disposeLatex()
        disposeMath()
    }
}

/// Built-in `opencode.latex` TUI plugin definition registering `latex` and `math` fenced code-block renderers.
// parity: latex/src/plugin.ts#default [status=implemented hash=98eb4c66532d]
public let latexPlugin: PluginTui.Definition = PluginTui.define(
    PluginTui.Definition(
        id: "opencode.latex",
        setup: setupLatexPlugin
    )
)

/// Convenience entrypoints for wiring the built-in `opencode.latex` plugin into OpenTUI `MarkdownRenderable`
/// and `TUIPluginHost` runtimes.
public enum LatexPlugin {
    public static let id: String = "opencode.latex"
    public static let languages: [String] = ["latex", "math"]
    public static let definition: PluginTui.Definition = latexPlugin

    /// Renders strict display-mode LaTeX into a Unicode string, returning `source` verbatim on parse/range errors.
    public static func renderCodeBlock(_ source: String) -> String {
        do {
            return try renderLatexToString(source, options: RenderLatexOptions(strict: true, displayMode: true))
        } catch {
            return source
        }
    }

    /// Creates the `MarkdownCodeBlockRendererMap` (`"latex"` and `"math"`) wired to the active `ResolvedTheme`.
    public static func createCodeBlockRenderers(
        context: any RenderContext,
        theme: @escaping () -> ResolvedTheme
    ) -> MarkdownCodeBlockRendererMap {
        let render = createLatexCodeBlockRenderer(context) {
            let resolved = theme()
            return LatexOptions(
                text: .rgba(resolved.text.base),
                subdued: .rgba(resolved.text.muted)
            )
        }
        return [
            "latex": render,
            "math": render,
        ]
    }

    /// Invokes `register` for `"latex"` and `"math"` using the OpenTUI code-block renderer bound to `renderer` and `theme`.
    public static func setup(
        renderer: any RenderContext,
        theme: @escaping () -> ResolvedTheme,
        register: (String, @escaping MarkdownCodeBlockRenderer) -> Void
    ) {
        let render = createLatexCodeBlockRenderer(renderer) {
            let resolved = theme()
            return LatexOptions(
                text: .rgba(resolved.text.base),
                subdued: .rgba(resolved.text.muted)
            )
        }
        register("latex", render)
        register("math", render)
    }

    /// Registers `"latex"` and `"math"` string code-block renderers on a `TUIPluginHost.PluginRuntimeContext`.
    @discardableResult
    public static func register(on context: TUIPluginHost.PluginRuntimeContext) throws -> @Sendable () -> Void {
        let disposeLatex = try context.registerCodeBlockRenderer(language: "latex") { source in
            LatexPlugin.renderCodeBlock(source)
        }
        let disposeMath = try context.registerCodeBlockRenderer(language: "math") { source in
            LatexPlugin.renderCodeBlock(source)
        }
        return {
            disposeLatex()
            disposeMath()
        }
    }
}

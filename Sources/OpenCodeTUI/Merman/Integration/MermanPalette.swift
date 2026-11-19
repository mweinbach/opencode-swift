import OpenTUICore

extension Merman {
    public struct OpenCodeDiagramPaletteAccent: Equatable, Hashable, Sendable {
        public let soft: RGBA
        public let clear: RGBA

        public init(soft: RGBA, clear: RGBA) {
            self.soft = soft
            self.clear = clear
        }
    }

    // parity: merman/src/palette.ts#OpenCodeDiagramPaletteInput [status=implemented hash=9b8b748aaddf]
    public struct OpenCodeDiagramPaletteInput: Equatable, Hashable, Sendable {
        public let text: RGBA
        public let subdued: RGBA
        public let info: RGBA
        public let success: RGBA
        public let warning: RGBA
        public let background: RGBA
        public let accent: OpenCodeDiagramPaletteAccent

        public init(
            text: RGBA,
            subdued: RGBA,
            info: RGBA,
            success: RGBA,
            warning: RGBA,
            background: RGBA,
            accent: OpenCodeDiagramPaletteAccent
        ) {
            self.text = text
            self.subdued = subdued
            self.info = info
            self.success = success
            self.warning = warning
            self.background = background
            self.accent = accent
        }
    }

    // parity: merman/src/palette.ts#OpenCodeDiagramPalette [status=implemented hash=0431fd7e37e0]
    public struct OpenCodeDiagramPalette: Equatable, Hashable, Sendable {
        public let text: RGBA
        public let primary: RGBA
        public let secondary: RGBA
        public let muted: RGBA
        public let warning: RGBA
        public let background: RGBA
        public let request: RGBA
        public let response: RGBA
        public let note: RGBA
        public let noteBackground: RGBA
        public let boxText: RGBA
        public let boxBorder: RGBA
        public let line: RGBA
        public let labelBackground: RGBA
        public let group: RGBA
        public let groupText: RGBA
        public let marker: RGBA
        public let noteBorder: RGBA
        public let noteText: RGBA
        public let noteConnector: RGBA

        public init(
            text: RGBA,
            primary: RGBA,
            secondary: RGBA,
            muted: RGBA,
            warning: RGBA,
            background: RGBA,
            request: RGBA,
            response: RGBA,
            note: RGBA,
            noteBackground: RGBA,
            boxText: RGBA,
            boxBorder: RGBA,
            line: RGBA,
            labelBackground: RGBA,
            group: RGBA,
            groupText: RGBA,
            marker: RGBA,
            noteBorder: RGBA,
            noteText: RGBA,
            noteConnector: RGBA
        ) {
            self.text = text
            self.primary = primary
            self.secondary = secondary
            self.muted = muted
            self.warning = warning
            self.background = background
            self.request = request
            self.response = response
            self.note = note
            self.noteBackground = noteBackground
            self.boxText = boxText
            self.boxBorder = boxBorder
            self.line = line
            self.labelBackground = labelBackground
            self.group = group
            self.groupText = groupText
            self.marker = marker
            self.noteBorder = noteBorder
            self.noteText = noteText
            self.noteConnector = noteConnector
        }

        public func asColorOverrides() -> MermaidPaletteColorOverrides {
            MermaidPaletteColorOverrides(
                text: .rgba(text),
                primary: .rgba(primary),
                secondary: .rgba(secondary),
                muted: .rgba(muted),
                warning: .rgba(warning),
                background: .rgba(background),
                request: .rgba(request),
                response: .rgba(response),
                note: .rgba(note),
                noteBackground: .rgba(noteBackground),
                boxText: .rgba(boxText),
                boxBorder: .rgba(boxBorder),
                line: .rgba(line),
                labelBackground: .rgba(labelBackground),
                group: .rgba(group),
                groupText: .rgba(groupText),
                marker: .rgba(marker),
                noteBorder: .rgba(noteBorder),
                noteText: .rgba(noteText),
                noteConnector: .rgba(noteConnector)
            )
        }
    }

    // parity: merman/src/palette.ts#createOpenCodeDiagramPalette [status=implemented hash=98755388d349]
    public static func createOpenCodeDiagramPalette(_ input: OpenCodeDiagramPaletteInput) -> OpenCodeDiagramPalette {
        let secondary = blendColor(input.text, input.subdued, 0.5)
        let muted = blendColor(input.text, input.subdued, 0.7)
        return OpenCodeDiagramPalette(
            text: input.text,
            primary: input.text,
            secondary: secondary,
            muted: muted,
            warning: input.info,
            background: input.background,
            request: input.success,
            response: input.warning,
            note: input.text,
            noteBackground: blendColor(input.background, input.subdued, 0.25),
            boxText: input.text,
            boxBorder: muted,
            line: input.subdued,
            labelBackground: RGBA.fromValues(input.text.r, input.text.g, input.text.b, 0.08),
            group: input.accent.soft,
            groupText: input.accent.soft,
            marker: secondary,
            noteBorder: input.accent.soft,
            noteText: input.accent.clear,
            noteConnector: input.accent.soft
        )
    }

    // parity: merman/src/palette.ts#resolveOpenCodeDiagramPalette [status=implemented hash=2a8ed4f79259]
    public static func resolveOpenCodeDiagramPalette(
        theme: ResolvedTheme,
        mode: Mode
    ) -> OpenCodeDiagramPalette {
        let scales = theme.categorical
        let accent = scales.count > 3 ? scales[3] : scales[0]
        return createOpenCodeDiagramPalette(OpenCodeDiagramPaletteInput(
            text: theme.text.base,
            subdued: theme.text.muted,
            info: theme.text.feedback.info.base,
            success: theme.text.feedback.success.base,
            warning: theme.text.feedback.warning.base,
            background: theme.background.base,
            accent: OpenCodeDiagramPaletteAccent(
                soft: accent[mode == .dark ? HueStep.s300 : HueStep.s700],
                clear: accent[mode == .dark ? HueStep.s200 : HueStep.s800]
            )
        ))
    }
}

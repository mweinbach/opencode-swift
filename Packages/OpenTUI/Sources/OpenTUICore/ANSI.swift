/// Terminal ANSI / CSI escape sequence builders matching `packages/core/src/ansi.ts`.
// parity: core/src/ansi.ts#ANSI [status=implemented hash=e2da00c730e0]
public enum ANSI {
    public static let switchToAlternateScreen = "\u{1B}[?1049h"
    public static let switchToMainScreen = "\u{1B}[?1049l"
    public static let reset = "\u{1B}[0m"
    public static let resetScrollRegion = "\u{1B}[r"
    public static let home = "\u{1B}[H"
    public static let clearScreen = "\u{1B}[2J"
    public static let clearSavedLines = "\u{1B}[3J"
    public static let resetBackground = "\u{1B}[49m"
    public static let bracketedPasteStart = "\u{1B}[200~"
    public static let bracketedPasteEnd = "\u{1B}[201~"

    public static func scrollDown(_ lines: Int) -> String {
        "\u{1B}[\(lines)T"
    }

    public static func scrollIntoHistory(_ lines: Int) -> String {
        let clamped = max(0, min(lines, 4000))
        let newlines = String(repeating: "\n", count: clamped)
        let extra = lines > 4000 ? "\u{1B}[\(lines - 4000)S" : ""
        return "\u{1B}[65535H\(newlines)\(extra)"
    }

    public static func moveCursor(row: Int, col: Int) -> String {
        "\u{1B}[\(row);\(col)H"
    }

    public static func moveCursorAndClear(row: Int, col: Int) -> String {
        "\u{1B}[\(row);\(col)H\u{1B}[J"
    }

    public static func setRgbBackground(r: Int, g: Int, b: Int) -> String {
        "\u{1B}[48;2;\(r);\(g);\(b)m"
    }
}

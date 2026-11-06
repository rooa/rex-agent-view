import AppKit

struct AgentPalette: Equatable {
    let id: String
    let background: NSColor
    let surface: NSColor
    let text: NSColor
    let secondary: NSColor
    let tertiary: NSColor
    let border: NSColor
    let accent: NSColor
    let selection: NSColor
    let selectedText: NSColor
    let success: NSColor
    let warning: NSColor
    let danger: NSColor
}

/// Reads Rex's own palette resources and the current app's preferences. It never
/// writes settings or reads the installed Rex app's separate preference domain.
@MainActor
enum AgentTheme {
    private struct Color: Decodable {
        let red, green, blue: CGFloat
        let alpha: CGFloat?
        let colorSpace: String?

        var native: NSColor {
            if colorSpace == "display-p3" {
                return NSColor(displayP3Red: red, green: green, blue: blue, alpha: alpha ?? 1)
            }
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha ?? 1)
        }
    }

    private struct BundledTheme: Decodable {
        let id: String
        let semantic: [String: Color]
    }

    private struct ImportedTheme: Decodable {
        struct Palette: Decodable {
            let background, foreground: Color
            let cursor, selectionBackground, selectionForeground: Color?
            let ansi: [Color]?
        }
        let id: String
        let palette: Palette
    }

    private static let catalog: [String: [String: Color]] = {
        let path = "SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json"
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(path),
              let data = try? Data(contentsOf: url),
              let themes = try? JSONDecoder().decode([BundledTheme].self, from: data) else { return [:] }
        return Dictionary(themes.map { ($0.id, $0.semantic) }, uniquingKeysWith: { _, last in last })
    }()

    static func palette(for view: NSView) -> AgentPalette {
        // Rex applies its appearance to the window, which can differ from macOS.
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let defaults = UserDefaults.standard
        let id = defaults.string(forKey: dark ? "Workspace.darkThemeID" : "Workspace.lightThemeID")
            ?? (dark ? "merino-dark" : "merino-light")
        let fallback = basePalette(id: id, dark: dark)

        if let colors = catalog[id] {
            func color(_ key: String, _ otherwise: NSColor) -> NSColor { colors[key]?.native ?? otherwise }
            return AgentPalette(
                id: id,
                background: color("terminalBackground", fallback.background),
                surface: color("surfaceRaised", fallback.surface),
                text: color("content", fallback.text),
                secondary: color("contentSecondary", fallback.secondary),
                tertiary: color("contentTertiary", fallback.tertiary),
                border: color("stroke", fallback.border),
                accent: color("accent", fallback.accent),
                selection: color("selection", fallback.selection),
                selectedText: color("selectionForeground", fallback.selectedText),
                success: color("success", fallback.success),
                warning: color("warning", fallback.warning),
                danger: color("danger", fallback.danger)
            )
        }

        // Imported palettes are stored as JSON Data rather than in themes.json.
        // Rex supplies raw terminal colors here; derive only the subdued UI roles.
        if let data = defaults.data(forKey: "Workspace.customThemes"),
           let themes = try? JSONDecoder().decode([ImportedTheme].self, from: data),
           let theme = themes.first(where: { $0.id == id }) {
            let p = theme.palette
            func ansi(_ index: Int, _ otherwise: NSColor) -> NSColor {
                guard let colors = p.ansi, colors.indices.contains(index) else { return otherwise }
                return colors[index].native
            }
            return derivedPalette(
                id: id, background: p.background.native, text: p.foreground.native,
                accent: p.cursor?.native ?? ansi(4, fallback.accent),
                selection: p.selectionBackground?.native,
                selectedText: p.selectionForeground?.native,
                success: ansi(2, fallback.success), warning: ansi(3, fallback.warning),
                danger: ansi(1, fallback.danger)
            )
        }
        return fallback
    }

    private static func basePalette(id: String, dark: Bool) -> AgentPalette {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: 1)
        }
        return derivedPalette(
            id: id, background: color(dark ? 0x0d1117 : 0xffffff),
            text: color(dark ? 0xe6edf3 : 0x1f2328),
            accent: color(dark ? 0x2f81f7 : 0x0969da),
            success: color(dark ? 0x3fb950 : 0x1a7f37),
            warning: color(dark ? 0xd29922 : 0x9a6700),
            danger: color(dark ? 0xf85149 : 0xcf222e)
        )
    }

    private static func derivedPalette(
        id: String, background: NSColor, text: NSColor, accent: NSColor,
        selection: NSColor? = nil, selectedText: NSColor? = nil,
        success: NSColor, warning: NSColor, danger: NSColor
    ) -> AgentPalette {
        func blend(_ amount: CGFloat) -> NSColor {
            background.blended(withFraction: amount, of: text) ?? text
        }
        return AgentPalette(
            id: id, background: background, surface: blend(0.06), text: text,
            secondary: blend(0.65), tertiary: blend(0.48), border: blend(0.18),
            accent: accent, selection: selection ?? blend(0.2),
            selectedText: selectedText ?? text, success: success, warning: warning, danger: danger
        )
    }
}

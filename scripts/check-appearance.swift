import AppKit

@main
@MainActor
struct AppearanceCheck {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "rex-agent-appearance-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "unrelated-setting")
        let appearance = AgentAppearance(defaults: defaults)
        try require(appearance.settings == AgentFontSettings(), "fresh appearance did not use native defaults")
        let families = NSFontManager.shared.availableFontFamilies
        let textFamily = families.contains("Avenir Next") ? "Avenir Next" : "Helvetica"
        let codeFamily = families.contains("Menlo") ? "Menlo" : "Courier"
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: AgentAppearance.didChangeNotification, object: appearance, queue: .main) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        appearance.update(AgentFontSettings(textFamily: textFamily, textSize: 18, codeFamily: codeFamily, codeSize: 14))
        try require(changes == 1, "font update did not notify existing panes")
        let restored = AgentAppearance(defaults: defaults)
        try require(restored.settings == appearance.settings, "font settings did not persist")
        try require(restored.settings.textFont().familyName == textFamily && restored.settings.textFont().pointSize == 18, "selected text font was not resolved")
        try require(restored.settings.codeFont().familyName == codeFamily && restored.settings.codeFont().pointSize == 14, "selected code font was not resolved")
        let heading = restored.settings.textFont(size: 24, weight: .bold, italic: true)
        let traits = NSFontManager.shared.traits(of: heading)
        try require(heading.familyName == textFamily && heading.pointSize == 24 && traits.contains(.boldFontMask) && traits.contains(.italicFontMask), "heading traits lost the selected family, size, bold, or italic")
        var unavailable = restored.settings
        unavailable.textFamily = "Rex Missing Font Fixture"
        try require(unavailable.textFont().pointSize == 18, "missing installed font failed to fall back safely")
        appearance.update(appearance.settings)
        try require(changes == 1, "unchanged settings needlessly re-rendered panes")
        print("PASS persisted fonts, native fallback, bold/italic traits and change notification")

        let panel = AgentAppearanceViewController(appearance: appearance)
        panel.view.frame = NSRect(x: 0, y: 0, width: 500, height: 420)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func named(_ id: String) -> NSView? { views(panel.view).first { $0.accessibilityIdentifier() == id } }
        let size = named("rex-agent.appearance.text-size") as! NSTextField
        size.doubleValue = 20
        NSApp.sendAction(size.action!, to: size.target, from: size)
        try require(appearance.settings.textSize == 20, "native size control did not update the shared preference")
        let preview = named("rex-agent.appearance.preview") as! NSTextView
        let previewFont = preview.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try require(previewFont?.familyName == textFamily && previewFont?.pointSize == 20, "preview did not update to the chosen font")
        let stepper = views(panel.view).compactMap { $0 as? NSStepper }.first { $0.tag == 1 }!
        stepper.doubleValue = 16.5
        NSApp.sendAction(stepper.action!, to: stepper.target, from: stepper)
        let codePreviewFont = preview.textStorage?.attribute(.font, at: preview.string.utf16.count - 1, effectiveRange: nil) as? NSFont
        try require(appearance.settings.textSize == 20 && appearance.settings.codeSize == 16.5 && codePreviewFont?.pointSize == 16.5, "code size did not change independently from text")
        (named("rex-agent.appearance.reset") as! NSButton).performClick(nil)
        try require(appearance.settings == AgentFontSettings(), "Reset did not restore the font defaults")
        try require(defaults.string(forKey: "unrelated-setting") == "keep", "Reset touched unrelated Rex settings")
        try require(AgentAppearance(defaults: defaults).settings == AgentFontSettings(), "Reset did not persist")
        print("PASS native settings controls, live preview and font-only reset")
        appearance.update(AgentFontSettings(textSize: .nan, codeSize: 1))
        try require(appearance.settings.textSize == 15 && appearance.settings.codeSize == 8, "invalid font sizes were not normalized")
        appearance.update(AgentFontSettings(textSize: 100, codeSize: 100))
        try require(appearance.settings.textSize == 48 && appearance.settings.codeSize == 48, "font sizes exceeded the supported controls range")
        print("PASS safe point-size bounds")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "AppearanceCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}

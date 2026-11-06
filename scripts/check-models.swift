import AppKit

@main
@MainActor
struct ModelCheck {
    static func main() {
        _ = NSApplication.shared
        let controls = AgentModelControls()
        let popups = controls.arrangedSubviews.compactMap { $0 as? NSPopUpButton }
        let model = popups[0], effort = popups[1]
        let options = [AgentModelOption(["id": "opus", "label": "Claude Opus", "resolvedModel": "gateway-opus", "efforts": ["low", "medium", "high"]])!,
                       AgentModelOption(["id": "sonnet", "label": "Claude Sonnet", "efforts": ["low", "medium", "high"], "defaultEffort": "medium"])!]
        func require(_ condition: Bool, _ message: String) {
            if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        controls.update(options: options, selectedModel: nil, selectedEffort: nil, resolvedModel: "gateway-opus", resolvedEffort: "high")
        require(model.titleOfSelectedItem == "Claude Opus", "inherited model does not show its friendly catalog label")
        require(effort.titleOfSelectedItem == "High", "known inherited effort is not visible")
        require(controls.selectedModel == nil && controls.selectedEffort == nil, "display labels became explicit overrides")
        model.menu?.delegate?.menuWillOpen?(model.menu!)
        require(model.item(at: 0)?.title == "Use agent default", "model menu has no clear reset choice")
        model.menu?.delegate?.menuDidClose?(model.menu!)
        require(model.titleOfSelectedItem == "Claude Opus", "closing the model menu lost its inherited label")
        var changed: (String?, String?)?
        controls.onChange = { changed = ($0, $1) }
        model.selectItem(at: 2)
        NSApp.sendAction(model.action!, to: model.target, from: model)
        require(changed?.0 == "sonnet" && changed?.1 == nil, "model change did not reset the effort override")
        require(effort.titleOfSelectedItem == "Medium", "model change retained the previous model's resolved effort")
        model.selectItem(at: 0)
        NSApp.sendAction(model.action!, to: model.target, from: model)
        require(changed != nil && changed?.0 == nil && changed?.1 == nil, "Use agent default did not emit nil overrides")
        controls.update(options: options, selectedModel: nil, selectedEffort: nil, resolvedModel: "gateway-opus")
        require(effort.titleOfSelectedItem == "Default effort", "unknown Claude effort was guessed")
        controls.update(options: options, selectedModel: "opus", selectedEffort: "maximum", resolvedModel: nil)
        require(controls.selectedEffort == "maximum" && effort.titleOfSelectedItem == "Maximum", "persisted effort disappeared when absent from the catalog")
        print("PASS resolved labels, nil default semantics, model-change effort reset, unknown effort, and persisted selections")
    }
}

import AppKit

enum StatusItemMenuProviderNavigationDirection {
    case previous
    case next
}

protocol StatusItemMenuPersistentActionDelegate: AnyObject {
    func performPersistentRefreshAction()
    func performPersistentSettingsAction()
    func performPersistentQuitAction()
    func performProviderNavigation(_ direction: StatusItemMenuProviderNavigationDirection)
}

final class StatusItemMenu: NSMenu {
    weak var persistentActionDelegate: StatusItemMenuPersistentActionDelegate?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let action = Self.persistentAction(for: event) {
            switch action {
            case .refresh:
                self.persistentActionDelegate?.performPersistentRefreshAction()
            case .settings:
                self.persistentActionDelegate?.performPersistentSettingsAction()
            case .quit:
                self.persistentActionDelegate?.performPersistentQuitAction()
            }
            return true
        }
        if let direction = Self.providerNavigationDirection(for: event),
           self.items.first?.view is ProviderSwitcherView
        {
            self.persistentActionDelegate?.performProviderNavigation(direction)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    private enum PersistentAction {
        case refresh
        case settings
        case quit
    }

    private nonisolated static func persistentAction(for event: NSEvent) -> PersistentAction? {
        guard event.type == .keyDown else { return nil }

        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevantModifiers == .command else { return nil }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            return .refresh
        case ",":
            return .settings
        case "q":
            return .quit
        default:
            return nil
        }
    }

    nonisolated static func providerNavigationDirection(
        for event: NSEvent) -> StatusItemMenuProviderNavigationDirection?
    {
        guard event.type == .keyDown else { return nil }
        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevantModifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 123:
            return .previous
        case 124:
            return .next
        default:
            return nil
        }
    }

    /// Tab and Shift-Tab, plus Shift-Command-[ and ] as in Chrome, which the trackpad's top-edge swipe
    /// sends. Matched on key code: Shift turns the characters into { and }.
    nonisolated static func providerSwitcherTabNavigationDirection(
        for event: NSEvent) -> StatusItemMenuProviderNavigationDirection?
    {
        guard event.type == .keyDown else { return nil }
        let relevantModifiers = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift,
            .function,
        ])
        if [33, 30].contains(event.keyCode) {
            guard relevantModifiers == [.command, .shift] else { return nil }
            return event.keyCode == 33 ? .previous : .next
        }
        guard event.keyCode == 48 else { return nil }
        switch relevantModifiers {
        case []:
            return .next
        case [.shift]:
            return .previous
        default:
            return nil
        }
    }

    nonisolated static func providerSelectionIndex(for event: NSEvent) -> Int? {
        guard event.type == .keyDown else { return nil }
        let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard relevantModifiers == .command,
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let number = Int(characters),
              (1...9).contains(number)
        else {
            return nil
        }
        return number - 1
    }
}

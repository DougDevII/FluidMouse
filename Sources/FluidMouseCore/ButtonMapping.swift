import Foundation

/// Modifier keys that can accompany a keyboard action.
/// Raw values are independent of CoreGraphics and only meaningful to this package.
public enum KeystrokeModifier: Int, Codable, CaseIterable, Hashable {
    case shift = 2
    case control = 4
    case option = 8
    case command = 16
}

public enum ScrollDirection: String, Codable, CaseIterable, Hashable {
    case up
    case down
}

/// System actions triggered by well-known default keyboard shortcuts.
public enum SystemAction: String, Codable, CaseIterable, Hashable {
    case missionControl
    case appExpose
    case showDesktop
    case spotlight
    case launchpad
    case spaceLeft
    case spaceRight
    case volumeUp
    case volumeDown
    case mute
    case playPause
    case nextTrack
    case previousTrack
    case brightnessUp
    case brightnessDown
}

/// How a keyboard mapping behaves on the mouse button.
public enum KeyBehavior: String, Codable, CaseIterable, Hashable {
    /// Sequence identical to a physical keyboard tap; the system sees the
    /// modifiers pressed and released via flagsChanged.
    case tap
    /// Modifiers and key stay down while the button is held.
    case hold
}

public struct KeyCombination: Codable, Equatable, Hashable {
    public var keycode: Int
    public var modifiers: Set<KeystrokeModifier>
    /// nil behaves as .tap for configurations that predate the option.
    public var behavior: KeyBehavior?

    public init(keycode: Int, modifiers: Set<KeystrokeModifier> = [], behavior: KeyBehavior? = nil) {
        self.keycode = keycode
        self.modifiers = modifiers
        self.behavior = behavior
    }

    public var effectiveBehavior: KeyBehavior { behavior ?? .tap }
}

/// What a mouse button does. `unchanged` means keep the native behavior.
public enum ButtonAction: Codable, Equatable, Hashable {
    case unchanged
    case disabled
    case scroll(ScrollDirection)
    case click(button: Int)
    case key(KeyCombination)
    case system(SystemAction)
}

/// Decision taken for a button event. Pure so it can be unit tested.
public enum ButtonPlan: Equatable {
    case passThrough
    case suppress
    case clickDown(button: Int)
    case clickUp(button: Int)
    case clickDrag(button: Int)
    case execute(ButtonAction)
    case pressKey(KeyCombination)
    case releaseKey(KeyCombination)
}

public enum ButtonMappingResolver {
    /// Plans the handling of a button down or up event given the configured mapping.
    public static func plan(button: Int, down: Bool, mapping: ButtonAction?) -> ButtonPlan {
        guard let mapping, mapping != .unchanged else { return .passThrough }
        switch mapping {
        case .unchanged:
            return .passThrough
        case .disabled:
            return .suppress
        case .click(let target):
            guard target != button else { return .passThrough }
            return down ? .clickDown(button: target) : .clickUp(button: target)
        case .key(let combination) where combination.effectiveBehavior == .hold:
            return down ? .pressKey(combination) : .releaseKey(combination)
        case .scroll, .key, .system:
            return down ? .execute(mapping) : .suppress
        }
    }

    /// Plans the handling of a drag event, which only makes sense for click remaps.
    public static func planDrag(button: Int, mapping: ButtonAction?) -> ButtonPlan {
        guard case .click(let target)? = mapping, target != button else { return .passThrough }
        return .clickDrag(button: target)
    }
}

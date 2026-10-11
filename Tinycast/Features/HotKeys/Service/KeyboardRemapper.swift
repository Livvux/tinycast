import Foundation

/// One HID key mapping on every keyboard. See docs/features/hotkeys.md#per-keyboard-remapping.
@MainActor
final class KeyboardRemapper {
    private(set) var mapping: HIDKeyMapping?
    /// Karabiner's virtual keyboard already sent our key elsewhere when we last remapped it.
    private(set) var sawKarabinerConflict = false
    /// Held only while a mapping is live: it is also what delivers keyboards plugged in later.
    private var system: HIDEventSystem?

    var keyboards: [HIDEventSystem.Keyboard] {
        (system ?? HIDEventSystem())?.keyboards ?? []
    }

    /// Keyboards carrying the mapping, read back rather than remembered.
    var remappedKeyboardNames: [String] {
        guard let mapping, let system else { return [] }
        return system.keyboards.filter { system.keyMappings(of: $0).contains(mapping) }.map(\.name)
    }

    /// False when the HID event system is unavailable, so nothing could be placed.
    @discardableResult
    func apply(_ mapping: HIDKeyMapping?) -> Bool {
        guard mapping != self.mapping else { return true }
        guard let system = system ?? HIDEventSystem() else { return mapping == nil }
        let previous = self.mapping
        self.mapping = mapping
        sawKarabinerConflict = false
        for keyboard in system.keyboards {
            update(keyboard, replacing: previous, in: system)
        }
        guard mapping != nil else {
            self.system = nil
            return true
        }
        self.system = system
        system.onKeyboardConnected = { [weak self, weak system] keyboard in
            guard let self, let system else { return }
            update(keyboard, replacing: nil, in: system)
        }
        system.watchConnections()
        return true
    }

    /// Merges into what the keyboard already carries, so another tool's entries survive.
    private func update(
        _ keyboard: HIDEventSystem.Keyboard, replacing previous: HIDKeyMapping?,
        in system: HIDEventSystem
    ) {
        let existing = system.keyMappings(of: keyboard)
        let cleared = previous.flatMap { $0.removed(from: existing) } ?? existing
        if let mapping, HyperKeyConflictPolicy.isKarabinerVirtualKeyboard(named: keyboard.name),
            mapping.conflicts(with: cleared)
        {
            sawKarabinerConflict = true
        }
        let wanted = mapping.map { $0.merged(into: cleared) } ?? cleared
        guard wanted != existing else { return }
        system.setKeyMappings(wanted, on: keyboard)
    }
}

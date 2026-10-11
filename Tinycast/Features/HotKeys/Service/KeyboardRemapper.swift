import Foundation

/// One HID key mapping on every keyboard. See docs/features/hotkeys.md#per-keyboard-remapping.
@MainActor
final class KeyboardRemapper {
    private(set) var mapping: HIDKeyMapping?
    private(set) var sawKarabinerConflict = false

    private let defaults: UserDefaults
    /// Kept for the app's life once needed: it is also what delivers keyboards plugged in later.
    private lazy var system: HIDEventSystem? = makeSystem()

    /// Survives a crash or force quit, which skip teardown and leave the remap on the keyboards.
    private static let mayHaveLeftMappingKey = "hyperKeyMayHaveLeftMapping"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var keyboards: [HIDEventSystem.Keyboard] { system?.keyboards ?? [] }

    /// Keyboards carrying the mapping, read back rather than remembered.
    var remappedKeyboardNames: [String] {
        guard let mapping, let system else { return [] }
        return system.keyboards.filter { system.keyMappings(of: $0).contains(mapping) }.map(\.name)
    }

    /// False when the HID event system is unavailable, so nothing could be placed.
    @discardableResult
    func apply(_ mapping: HIDKeyMapping?) -> Bool {
        guard mapping != self.mapping else { return true }
        self.mapping = mapping
        return reconcileAll() != nil
    }

    func clearLeftovers() {
        guard mapping == nil, defaults.bool(forKey: Self.mayHaveLeftMappingKey) else { return }
        reconcileAll()
    }

    /// True when a keyboard had lost the mapping and now carries it again.
    func repair() -> Bool {
        guard mapping != nil else { return false }
        return reconcileAll() ?? false
    }

    private func makeSystem() -> HIDEventSystem? {
        guard let system = HIDEventSystem() else { return nil }
        system.onKeyboardConnected = { [weak self, weak system] keyboard in
            guard let self, let system, mapping != nil else { return }
            update(keyboard, in: system)
        }
        system.watchConnections()
        return system
    }

    /// Nil without the HID event system; otherwise whether any keyboard was rewritten.
    @discardableResult
    private func reconcileAll() -> Bool? {
        guard let system else { return nil }
        // Recorded before the first write, so a crash midway still leaves the marker behind.
        if mapping != nil { defaults.set(true, forKey: Self.mayHaveLeftMappingKey) }
        sawKarabinerConflict = false
        var rewrote = false
        for keyboard in system.keyboards where update(keyboard, in: system) {
            rewrote = true
        }
        if mapping == nil { defaults.removeObject(forKey: Self.mayHaveLeftMappingKey) }
        return rewrote
    }

    @discardableResult
    private func update(_ keyboard: HIDEventSystem.Keyboard, in system: HIDEventSystem) -> Bool {
        let existing = system.keyMappings(of: keyboard)
        if let mapping, HyperKeyConflictPolicy.isKarabinerVirtualKeyboard(named: keyboard.name),
            mapping.conflicts(with: existing.filter { !HIDKeyMapping.hyperKeyMappings.contains($0) })
        {
            sawKarabinerConflict = true
        }
        let wanted = HIDKeyMapping.reconciled(existing, wanting: mapping)
        guard wanted != existing else { return false }
        return system.setKeyMappings(wanted, on: keyboard)
    }
}

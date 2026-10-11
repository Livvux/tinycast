import Foundation

/// One `UserKeyMapping` entry, usages packed as `page << 32 | usage` the way IOKit stores them.
struct HIDKeyMapping: Hashable, Sendable {
    let source: UInt64
    let destination: UInt64

    static let capsLock: UInt64 = 0x7_0000_0039
    static let f18: UInt64 = 0x7_0000_006D
    static let rightControl: UInt64 = 0x7_0000_00E4

    static let capsLockToF18 = HIDKeyMapping(source: capsLock, destination: f18)
    static let capsLockToRightControl = HIDKeyMapping(source: capsLock, destination: rightControl)

    /// Every entry the Hyper Key places, so one left behind by any earlier state is found again.
    static let hyperKeyMappings: Set<HIDKeyMapping> = [capsLockToF18, capsLockToRightControl]

    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }

    init?(dictionary: [String: Any]) {
        guard let source = Self.usage(dictionary[Self.sourceKey]),
            let destination = Self.usage(dictionary[Self.destinationKey])
        else { return nil }
        self.init(source: source, destination: destination)
    }

    var dictionary: [String: Any] {
        [Self.sourceKey: NSNumber(value: source), Self.destinationKey: NSNumber(value: destination)]
    }

    static func mappings(from value: Any?) -> [HIDKeyMapping] {
        (value as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(HIDKeyMapping.init) }
    }

    static func reconciled(_ existing: [HIDKeyMapping], wanting wanted: HIDKeyMapping?) -> [HIDKeyMapping] {
        let cleared = existing.filter { !hyperKeyMappings.contains($0) }
        guard let wanted else { return cleared }
        return cleared.filter { $0.source != wanted.source } + [wanted]
    }

    func conflicts(with existing: [HIDKeyMapping]) -> Bool {
        existing.contains { $0.source == source && $0.destination != destination }
    }

    // Property lists hand back NSNumber; a hand-built dictionary may hold plain integers.
    private static func usage(_ value: Any?) -> UInt64? {
        switch value {
        case let number as NSNumber: return number.uint64Value
        case let integer as Int: return UInt64(exactly: integer)
        case let integer as UInt64: return integer
        default: return nil
        }
    }
}

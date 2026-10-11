import Foundation

@main
struct HyperKeyTest {
    nonisolated(unsafe) static var failures = 0

    static func main() {
        keyMappingMerge()
        keyMappingRemoval()
        keyMappingConflicts()
        keyMappingParsing()
        knownApps()
        modifierKeysPreferences()
        karabinerConfig()
        print(failures == 0 ? "All hyper key checks passed" : "\(failures) hyper key check(s) failed")
        if failures > 0 { exit(1) }
    }

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    static let toF18 = HIDKeyMapping(source: HIDKeyMapping.capsLock, destination: HIDKeyMapping.f18)
    static let toRightControl = HIDKeyMapping(
        source: HIDKeyMapping.capsLock, destination: HIDKeyMapping.rightControl)
    static let otherTool = HIDKeyMapping(source: 0x7_0000_0029, destination: 0x7_0000_0035)

    static func keyMappingMerge() {
        check("merging into an empty keyboard places just ours", toF18.merged(into: []) == [toF18])
        check(
            "merging keeps another tool's entry for a different key",
            toF18.merged(into: [otherTool]) == [otherTool, toF18])
        check(
            "merging replaces any entry for the same source key",
            toRightControl.merged(into: [toF18, otherTool]) == [otherTool, toRightControl])
    }

    static func keyMappingRemoval() {
        check(
            "removing from a keyboard we never touched does nothing", toF18.removed(from: [otherTool]) == nil)
        check(
            "removing takes only our entry and leaves the rest",
            toF18.removed(from: [otherTool, toF18]) == [otherTool])
        check(
            "removing a different destination for the same key leaves it alone",
            toF18.removed(from: [toRightControl]) == nil)
    }

    static func keyMappingConflicts() {
        check("the same key sent elsewhere is a conflict", toF18.conflicts(with: [toRightControl]))
        check("our own mapping already in place is not a conflict", !toF18.conflicts(with: [toF18]))
        check("a mapping for another key is not a conflict", !toF18.conflicts(with: [otherTool]))
    }

    static func keyMappingParsing() {
        let raw: [Any] = [
            [
                HIDKeyMapping.sourceKey: NSNumber(value: HIDKeyMapping.capsLock),
                HIDKeyMapping.destinationKey: NSNumber(value: HIDKeyMapping.f18)
            ],
            [HIDKeyMapping.sourceKey: Int(0x7_0000_0029), HIDKeyMapping.destinationKey: Int(0x7_0000_0035)],
            [HIDKeyMapping.sourceKey: NSNumber(value: HIDKeyMapping.capsLock)],
            "not a mapping"
        ]
        check(
            "a UserKeyMapping array reads numbers and integers, skipping malformed entries",
            HIDKeyMapping.mappings(from: raw) == [toF18, otherTool])
        check("a missing UserKeyMapping reads as no mappings", HIDKeyMapping.mappings(from: nil).isEmpty)
        check(
            "a mapping survives a round trip through its dictionary",
            HIDKeyMapping(dictionary: toRightControl.dictionary) == toRightControl)
    }

    static func knownApps() {
        check(
            "Hyperkey and Superkey block the Hyper Key",
            HyperKeyConflictPolicy.severity(ofBundleID: "com.knollsoft.Hyperkey") == .blocking
                && HyperKeyConflictPolicy.severity(ofBundleID: "com.knollsoft.Superkey") == .blocking)
        check(
            "BetterTouchTool is only a warning",
            HyperKeyConflictPolicy.severity(ofBundleID: "com.hegenberg.BetterTouchTool") == .warning)
        check(
            "an unknown app is no conflict",
            HyperKeyConflictPolicy.severity(ofBundleID: "com.apple.Safari") == nil)
        check(
            "Karabiner's virtual keyboard is recognised by name",
            HyperKeyConflictPolicy.isKarabinerVirtualKeyboard(
                named: "Karabiner DriverKit VirtualHIDKeyboard 1.8.0")
                && !HyperKeyConflictPolicy.isKarabinerVirtualKeyboard(named: "Apple Internal Keyboard"))
        check(
            "1Password is a likely Secure Input holder",
            HyperKeyConflictPolicy.secureInputSuspects.contains("com.1password.1password"))
    }

    static func modifierKeysPreferences() {
        let prefix = HyperKeyConflictPolicy.modifierMappingPrefix
        let preferences: [String: Any] = [
            prefix + "1452-834-0": [toRightControl.dictionary],
            prefix + "1133-49948-0": [
                HIDKeyMapping(source: HIDKeyMapping.capsLock, destination: HIDKeyMapping.capsLock).dictionary
            ],
            prefix + "0-0-0": [toF18.dictionary],
            prefix + "1234-5-0": [otherTool.dictionary],
            "AppleKeyboardUIMode": 2
        ]
        let remaps = HyperKeyConflictPolicy.capsLockRemaps(in: preferences)
        check(
            "keyboards whose Caps Lock is moved are reported, sorted",
            remaps == [.init(vendorID: 0, productID: 0), .init(vendorID: 1452, productID: 834)])
        check("the 0-0-0 entry reads as the default keyboard", remaps.first?.isDefault == true)
        check(
            "no preferences means no Caps Lock conflicts",
            HyperKeyConflictPolicy.capsLockRemaps(in: [:]).isEmpty)
    }

    static func karabinerConfig() {
        func config(_ profiles: [[String: Any]]) -> Data {
            (try? JSONSerialization.data(withJSONObject: ["profiles": profiles])) ?? Data()
        }
        let simple: [String: Any] = [
            "selected": true,
            "simple_modifications": [["from": ["key_code": "caps_lock"], "to": [["key_code": "escape"]]]]
        ]
        let complex: [String: Any] = [
            "selected": true,
            "complex_modifications": [
                "rules": [["manipulators": [["from": ["key_code": "right_command"], "type": "basic"]]]]
            ]
        ]
        let perDevice: [String: Any] = [
            "selected": true,
            "devices": [["simple_modifications": [["from": ["key_code": "left_option"]]]]]
        ]
        let unselected: [String: Any] = [
            "selected": false,
            "simple_modifications": [["from": ["key_code": "caps_lock"]]]
        ]
        check(
            "a simple modification of the key is a conflict",
            HyperKeyConflictPolicy.karabinerRemaps("capsLock", config: config([simple])))
        check(
            "a complex modification of the key is a conflict",
            HyperKeyConflictPolicy.karabinerRemaps("rightCommand", config: config([complex])))
        check(
            "a per-device modification of the key is a conflict",
            HyperKeyConflictPolicy.karabinerRemaps("leftOption", config: config([perDevice])))
        check(
            "a profile that is not selected does not count",
            !HyperKeyConflictPolicy.karabinerRemaps("capsLock", config: config([unselected, complex])))
        check(
            "a modification of another key is not a conflict",
            !HyperKeyConflictPolicy.karabinerRemaps("rightShift", config: config([simple])))
        check(
            "an unreadable config is not a conflict",
            !HyperKeyConflictPolicy.karabinerRemaps("capsLock", config: Data("{".utf8)))
    }
}

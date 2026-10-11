import Foundation

@main
struct HyperKeyTest {
    nonisolated(unsafe) static var failures = 0

    static func main() {
        keyMappingReconcile()
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

    static let toF18 = HIDKeyMapping.capsLockToF18
    static let toRightControl = HIDKeyMapping.capsLockToRightControl
    static let otherTool = HIDKeyMapping(source: 0x7_0000_0029, destination: 0x7_0000_0035)

    static func keyMappingReconcile() {
        let otherCapsLock = HIDKeyMapping(source: HIDKeyMapping.capsLock, destination: 0x7_0000_0029)
        check("placing on an empty keyboard adds just ours", HIDKeyMapping.reconciled([], wanting: toF18) == [toF18])
        check(
            "placing keeps another tool's entry for a different key",
            HIDKeyMapping.reconciled([otherTool], wanting: toF18) == [otherTool, toF18])
        check(
            "placing replaces another entry for the same key",
            HIDKeyMapping.reconciled([otherCapsLock, otherTool], wanting: toF18) == [otherTool, toF18])
        check(
            "switching routes swaps one Hyper entry for the other",
            HIDKeyMapping.reconciled([toF18, otherTool], wanting: toRightControl) == [otherTool, toRightControl])
        check(
            "an entry already in place is left as it is",
            HIDKeyMapping.reconciled([otherTool, toF18], wanting: toF18) == [otherTool, toF18])
        check(
            "removing takes every Hyper entry, even one an earlier route left",
            HIDKeyMapping.reconciled([toRightControl, otherTool, toF18], wanting: nil) == [otherTool])
        check(
            "removing leaves another tool's Caps Lock entry alone",
            HIDKeyMapping.reconciled([otherCapsLock], wanting: nil) == [otherCapsLock])
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

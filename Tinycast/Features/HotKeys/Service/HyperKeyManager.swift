import AppKit
import Carbon.HIToolbox

/// Owns the Hyper Key's lifecycle and policy. See docs/features/hotkeys.md#the-hyper-key.
@MainActor
@Observable
final class HyperKeyManager: HealthCheckable {
    enum Status: Equatable {
        case off
        case active
        case needsAccessibility
        /// Another app's Hyper Key holds the keyboard; ours waits for it to quit.
        case blocked(appName: String)
        /// The HID event system refused the remap, so Caps Lock is still Caps Lock.
        case remapUnavailable
        /// Asleep, locked or another user's session: the keyboard is handed back meanwhile.
        case paused
    }

    private(set) var status: Status = .off

    /// A one-line problem worth a HUD: a blocking app, or Hyper pressed inside Secure Input.
    @ObservationIgnored var onProblem: ((String) -> Void)?
    @ObservationIgnored weak var healthTicker: HealthTicker?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let hotKeys: HotKeyManager
    @ObservationIgnored private let tap: HyperKeyTap
    @ObservationIgnored private let remapper = KeyboardRemapper()
    @ObservationIgnored private let secureInput = SecureInputMonitor()
    @ObservationIgnored private var observers: [NotificationToken] = []
    @ObservationIgnored private var pauseReasons: Set<PauseReason> = []

    private enum PauseReason {
        case asleep, screenLocked, sessionInactive
    }

    init(settings: AppSettings, hotKeys: HotKeyManager) {
        self.settings = settings
        self.hotKeys = hotKeys
        tap = HyperKeyTap(settings: settings)
    }

    func start() {
        secureInput.onChange = { [weak self] _ in self?.secureInputChanged() }
        observeSettings()
        observeSystem()
        apply()
    }

    func restart() {
        stop(.off)
        apply()
    }

    /// The HID remap outlives the process, so hand the key back before exiting.
    func prepareForTermination() {
        remapper.apply(nil)
    }

    func diagnostics() -> HyperKeyDiagnostics {
        let key = settings.hyperKey
        let keyboards = remapper.keyboards
        return HyperKeyDiagnostics(
            isActive: status == .active,
            activeKeyTitle: status == .active ? key.title : nil,
            eventTapEnabled: tap.isEnabled,
            runLoopSourceValid: tap.runLoopSourceIsValid,
            remappedKeyboards: remapper.remappedKeyboardNames,
            conflictingApps: HyperKeyConflictScanner.runningConflicts(),
            karabinerVirtualKeyboards: keyboards.map(\.name).filter(
                HyperKeyConflictPolicy.isKarabinerVirtualKeyboard),
            karabinerConflict: remapper.sawKarabinerConflict
                || HyperKeyConflictScanner.karabinerRemaps(key),
            capsLockMappingConflicts: key == .capsLock
                ? HyperKeyConflictScanner.capsLockRemaps().map { name(of: $0, among: keyboards) }
                : [],
            secureInput: secureInput.report())
    }

    // MARK: - Applying

    /// Idempotent: every input funnels here, and it converges on what the settings ask for.
    private func apply() {
        let key = settings.hyperKey
        guard let route = key.route(secureInputCompatible: isSecureInputCompatible) else {
            return stop(.off)
        }
        if let blocker = HyperKeyConflictScanner.runningBlocker() {
            if status != .blocked(appName: blocker) { onProblem?("Quit \(blocker) to use the Hyper Key") }
            return stop(.blocked(appName: blocker))
        }
        guard pauseReasons.isEmpty else { return stop(.paused) }
        if route.remap != nil, remapper.mapping == nil { tap.unlatchCapsLock() }
        guard remapper.apply(route.remap) else { return stop(.remapUnavailable) }
        tap.route = route
        healthTicker?.subscribe(self)
        status = tap.install() ? .active : .needsAccessibility
        syncSecureInputHotKeys()
    }

    private func stop(_ status: Status) {
        tap.route = nil
        tap.tearDown()
        remapper.apply(nil)
        healthTicker?.unsubscribe(self)
        self.status = status
        syncSecureInputHotKeys()
    }

    private var isSecureInputCompatible: Bool {
        settings.hyperKey.supportsSecureInputCompatibility && settings.hyperKeySecureInputCompatibility
    }

    /// One-second watchdog while a key is live. See docs/features/hotkeys.md#lifecycle.
    func healthCheck() {
        guard tap.route != nil else { return }
        secureInput.refresh()
        let previous = status
        if !tap.isInstalled {
            if tap.install() { status = .active }
        } else if !Permissions.isAccessibilityTrusted() {
            tap.tearDown()
            status = .needsAccessibility
        } else if tap.isEnabled == false {
            tap.reenable()
        }
        if status != previous { syncSecureInputHotKeys() }
    }

    // MARK: - Secure Input

    private func secureInputChanged() {
        // The tap saw neither end of anything typed inside, so a half-held chord is stale.
        tap.cancelHold()
        syncSecureInputHotKeys()
    }

    /// Inside Secure Input only Carbon hotkeys fire: ⌃ equivalents when compatible, else a hint.
    private func syncSecureInputHotKeys() {
        let isInside = status == .active && secureInput.isActive
        hotKeys.setSecureInputEquivalents(
            includesShift: isInside && isSecureInputCompatible ? settings.hyperKeyIncludesShift : nil)
        let swallowsCapsLock = isInside && settings.hyperKey == .capsLock && !isSecureInputCompatible
        hotKeys.setSecureInputHint(
            swallowsCapsLock ? KeyShortcut(carbonKeyCode: kVK_F18, carbonModifiers: 0) : nil
        ) { [weak self] in
            self?.onProblem?("The Hyper Key can't work while Secure Input is on")
        }
    }

    // MARK: - Observation

    /// Fires synchronously on main before the write lands, so the task re-arms, then applies.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.hyperKey
            _ = settings.hyperKeySecureInputCompatibility
            _ = settings.hyperKeyIncludesShift
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                observeSettings()
                apply()
            }
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observers = [
            observe(workspace, NSWorkspace.willSleepNotification) { $0.pause(.asleep) },
            observe(workspace, NSWorkspace.didWakeNotification) { $0.resume(.asleep) },
            observe(workspace, NSWorkspace.sessionDidResignActiveNotification) {
                $0.pause(.sessionInactive)
            },
            observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) {
                $0.resume(.sessionInactive)
            },
            // Caps Lock has to be Caps Lock again for a password typed at the lock screen.
            observe(distributed, Notification.Name("com.apple.screenIsLocked")) {
                $0.pause(.screenLocked)
            },
            observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) {
                $0.resume(.screenLocked)
            },
            observeBlockingApps(workspace, NSWorkspace.didLaunchApplicationNotification),
            observeBlockingApps(workspace, NSWorkspace.didTerminateApplicationNotification)
        ]
    }

    private func pause(_ reason: PauseReason) {
        pauseReasons.insert(reason)
        apply()
    }

    private func resume(_ reason: PauseReason) {
        pauseReasons.remove(reason)
        apply()
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ handler: @escaping @Sendable @MainActor (HyperKeyManager) -> Void
    ) -> NotificationToken {
        NotificationToken(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    handler(self)
                }
            }, center: center)
    }

    /// Only a known blocker coming or going can change the outcome, so others cost nothing.
    private func observeBlockingApps(
        _ center: NotificationCenter, _ name: Notification.Name
    ) -> NotificationToken {
        NotificationToken(
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleID = app?.bundleIdentifier,
                    HyperKeyConflictPolicy.severity(ofBundleID: bundleID) == .blocking
                else { return }
                MainActor.assumeIsolated { self?.apply() }
            }, center: center)
    }

    private func name(
        of identity: HyperKeyConflictPolicy.KeyboardIdentity, among keyboards: [HIDEventSystem.Keyboard]
    ) -> String {
        if identity.isDefault { return "All keyboards" }
        return keyboards.first {
            $0.vendorID == identity.vendorID && $0.productID == identity.productID
        }?.name ?? "Keyboard \(identity.vendorID)-\(identity.productID)"
    }
}

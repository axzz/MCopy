import AppKit
import SwiftData
import Carbon

class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var panel: ClipboardPanel?
    private var monitor: ClipboardMonitor?
    private var localMonitor: Any?
    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    // Accessed from a C callback — must bypass actor isolation
    nonisolated(unsafe) private static var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        setupMonitor()
        setupPanel()
        setupHotkeys()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        if let l = localMonitor  { NSEvent.removeMonitor(l) }
        for (_, ref) in hotKeyRefs { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        if let h = eventHandlerRef { RemoveEventHandler(h) }
    }

    // MARK: - Setup

    private var store: ClipboardStore?

    private func setupMonitor() {
        let container = MCopyApp.sharedModelContainer
        let s = ClipboardStore(modelContext: container.mainContext)
        store = s
        let m = ClipboardMonitor(store: s)
        m.start()
        monitor = m
    }

    private func setupPanel() {
        guard let store else { return }
        let p = ClipboardPanel(container: MCopyApp.sharedModelContainer, store: store)
        p.monitor = monitor
        panel = p
    }

    private func setupHotkeys() {
        // Carbon RegisterEventHotKey: works globally without Accessibility permission.
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                Task { @MainActor in
                    AppDelegate.shared?.handleHotKey(id: hkID.id)
                }
                return noErr
            },
            1, &eventSpec, nil, &eventHandlerRef
        )

        // Register stored shortcuts and listen for changes.
        let store = ShortcutStore.shared
        register(.activatePaste, shortcut: store.activatePaste)
        store.onChange = { [weak self] action, shortcut in
            self?.register(action, shortcut: shortcut)
        }

        // Local monitor: handles the Activate Paste shortcut while our own
        // panel is the key window (Carbon hotkey doesn't fire then).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let s = ShortcutStore.shared.activatePaste else { return event }
            let flags = event.modifierFlags.intersection(Shortcut.allowedModifiers)
            if flags == s.flags && event.keyCode == s.keyCode {
                self.togglePanel()
                return nil
            }
            return event
        }
    }

    private func register(_ action: ShortcutAction, shortcut: Shortcut?) {
        if let existing = hotKeyRefs[action] {
            UnregisterEventHotKey(existing)
            hotKeyRefs[action] = nil
        }
        guard let s = shortcut else { return }
        var ref: EventHotKeyRef?
        let keyID = EventHotKeyID(signature: 0x54505354, id: action.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(s.keyCode),
            s.carbonModifiers,
            keyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref { hotKeyRefs[action] = ref }
    }

    // MARK: - Public

    func togglePanel() {
        if let p = panel, p.isVisible {
            p.close()
        } else {
            panel?.showPanel()
        }
    }

    @MainActor
    private func handleHotKey(id: UInt32) {
        switch id {
        case ShortcutAction.activatePaste.hotKeyID:
            togglePanel()
        default:
            break
        }
    }
}

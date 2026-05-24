import SwiftUI
import AppKit
import Carbon
import Combine

// MARK: - Model

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt  // NSEvent.ModifierFlags.rawValue (masked)

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.allowedModifiers).rawValue
    }

    static let allowedModifiers: NSEvent.ModifierFlags =
        [.command, .shift, .option, .control]

    var flags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.allowedModifiers)
    }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var displayString: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option)  { s += "⌥" }
        if flags.contains(.shift)   { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        s += Self.keyName(for: keyCode)
        return s
    }

    /// Build a Shortcut from a keyDown event. Returns nil if the event has no
    /// usable key (e.g. modifier-only press).
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection(Self.allowedModifiers)
        // Require at least one modifier to avoid registering bare letters.
        guard !mods.isEmpty else { return nil }
        self.init(keyCode: event.keyCode, modifiers: mods)
    }

    // MARK: Key name lookup

    private static let specialKeys: [UInt16: String] = [
        36:  "⏎",      // Return
        48:  "⇥",      // Tab
        49:  "Space",
        51:  "⌫",      // Delete
        53:  "⎋",      // Escape
        76:  "⌅",      // Enter (keypad)
        117: "⌦",      // Forward delete
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3",  118: "F4",
        96:  "F5", 97:  "F6", 98: "F7",  100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    static func keyName(for keyCode: UInt16) -> String {
        if let s = specialKeys[keyCode] { return s }
        return translatedKey(keyCode) ?? "?"
    }

    private static func translatedKey(_ keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKey: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let err = UCKeyTranslate(
            layout, keyCode,
            UInt16(kUCKeyActionDisplay), 0,
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKey, 4, &length, &chars
        )
        guard err == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

// MARK: - Store

enum ShortcutAction: String, CaseIterable {
    case activatePaste

    var defaultsKey: String { "shortcut.\(rawValue)" }
    var hotKeyID: UInt32 {
        switch self {
        case .activatePaste: return 1
        }
    }
}

final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published var activatePaste: Shortcut? {
        didSet { persist(.activatePaste, activatePaste); onChange?(.activatePaste, activatePaste) }
    }

    var onChange: ((ShortcutAction, Shortcut?) -> Void)?

    private init() {
        // Default Activate Paste = ⌘⇧V to match the previous hardcoded binding.
        self.activatePaste = Self.load(.activatePaste)
            ?? Shortcut(keyCode: UInt16(kVK_ANSI_V), modifiers: [.command, .shift])
    }

    func binding(for action: ShortcutAction) -> Binding<Shortcut?> {
        switch action {
        case .activatePaste:
            return Binding(get: { self.activatePaste }, set: { self.activatePaste = $0 })
        }
    }

    private static func load(_ action: ShortcutAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    private func persist(_ action: ShortcutAction, _ shortcut: Shortcut?) {
        let key = action.defaultsKey
        if let s = shortcut, let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Recorder UI

struct KeyRecorderView: View {
    @Binding var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        ZStack {
            Text(label)
                .font(.system(size: 14, weight: recording ? .medium : .regular))
                .tracking(0.5)
                .foregroundStyle(recording ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .center)

            if shortcut != nil && !recording {
                HStack {
                    Spacer()
                    Button {
                        shortcut = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: 140)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.25),
                              lineWidth: recording ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { toggleRecording() }
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if recording { return "Type…" }
        return shortcut?.displayString ?? "None"
    }

    private func toggleRecording() {
        if recording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Escape with no modifiers cancels.
            if event.type == .keyDown,
               event.keyCode == 53,
               event.modifierFlags.intersection(Shortcut.allowedModifiers).isEmpty {
                stopRecording()
                return nil
            }
            if event.type == .keyDown, let s = Shortcut(event: event) {
                shortcut = s
                stopRecording()
                return nil
            }
            // Swallow other key events while recording.
            return event.type == .keyDown ? nil : event
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        recording = false
    }
}

import AppKit
import SwiftUI
import SwiftData

private struct MenuBarExtraContent: View {
    @Environment(\.openSettings) private var openSettings
    var toggleHistoryPanel: () -> Void

    var body: some View {
        Button("Show History") {
            toggleHistoryPanel()
        }
        Divider()
        Button("Settings…") {
            openSettings()
            MCopySettingsPresentation.activateAndBringToFront()
        }
        .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button("Quit MQCopy") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

@main
struct MCopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([ClipboardItem.self])
        // If the schema changed from a previous build, delete the old store and retry.
        if let container = try? ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ]) {
            return container
        }
        deleteDefaultStore()
        return try! ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        ])
    }()

    var body: some Scene {
        MenuBarExtra("MQCopy", systemImage: "doc.on.clipboard") {
            MenuBarExtraContent(toggleHistoryPanel: { appDelegate.togglePanel() })
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }

    private static func deleteDefaultStore() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }

        // SwiftData's default container writes default.store plus its
        // SQLite WAL/SHM siblings directly into Application Support.
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            try? FileManager.default.removeItem(at: appSupport.appendingPathComponent(name))
        }
    }
}

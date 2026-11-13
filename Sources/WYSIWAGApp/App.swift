import SwiftUI
import AppKit
import WYSIWAGCore

@main struct WYSIWAGApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label("WYSIWAG", systemImage: model.running ? "record.circle.fill" : "pause.circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(model.running ? Color.red : Color.secondary, Color.primary)
                .accessibilityLabel(model.tr(model.running ? "Capturing" : "Paused"))
        }
        Settings { SettingsView(model: model) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.showSettings()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showSettings()
        return true
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Text("WYSIWAG · " + model.tr(model.running ? "Capturing" : "Paused"))
        Text(model.tr(model.status)).font(.caption)
        if let failure = model.classifierFailure { Text(failure).font(.caption) }
        Divider()
        Button(model.tr(model.running ? "Pause capture" : "Resume capture")) { model.toggle() }
        Button(model.tr("Settings…")) { model.showSettings() }.keyboardShortcut(",")
        Button(model.tr("Open local folder")) { model.openFolder() }
        Divider()
        Button(model.tr("Quit WYSIWAG")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

import AppKit
import SwiftUI

@main
struct ConvertZApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("ConvertZ", id: "main") {
            ContentView(model: AppModel.shared)
        }
        .defaultSize(width: 720, height: 520)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About ConvertZ") { AppDelegate.showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { AppDelegate.addFiles() }.keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched from `swift run` there is no bundle, so ask to be a regular foreground app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.add(urls)
        // `open -a ConvertZ files... --args -autoConvert YES` starts converting straight away, for scripting.
        if UserDefaults.standard.bool(forKey: "autoConvert") { AppModel.shared.convert() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A conversion is still running."
        alert.informativeText = "Quitting stops it and discards the unfinished file. Finished files are kept."
        alert.addButton(withTitle: "Keep Converting")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        model.shutdown()
        return .terminateNow
    }

    static func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        if panel.runModal() == .OK { AppModel.shared.add(panel.urls) }
    }

    static func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Converts media with FFmpeg, a separate program included with this app under the GNU GPL v3. Source: ",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        credits.append(NSAttributedString(string: "ffmpeg.org", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://ffmpeg.org/download.html")!]))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

import AppKit
import GroveCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        // Only for a bare SwiftPM executable (`swift run`, no .app bundle). In a bundle this is
        // unnecessary, and with the macOS 26 SDK it has been seen to stop SwiftUI from opening
        // the first window (reported on sibling apps; not reproduced for Grove on macOS 27.2).
        if Bundle.main.bundleIdentifier == nil {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct GroveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `Grove /path/to/repo` (or `open -a Grove --args /path`): without this AppKit treats the
        // path as a document to open, and SwiftUI apps built with the macOS 26 SDK then never
        // create their first window. LaunchOptions reads the path itself.
        UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])
    }

    var body: some Scene {
        // One window per repository; a window without a value shows the welcome screen.
        WindowGroup("Grove", id: "repository", for: URL.self) { $url in
            RootView(url: $url)
                .frame(minWidth: 1000, minHeight: 640)
                .background(WindowTabbing())
        }
        .windowToolbarStyle(.unified)
        .commands { GroveCommands() }

        Settings { SettingsView() }
    }
}

struct GroveCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.repoModel) private var model

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { openWindow(id: "repository") }
                .keyboardShortcut("t")
            Button("Open Repository…") {
                if let url = RepositoryPicker.choose() { openWindow(value: url) }
            }
            .keyboardShortcut("o")
        }
        CommandMenu("Repository") {
            Button("Quick Open…") { model?.showPalette.toggle() }
                .keyboardShortcut("k")
                .disabled(model == nil)
            Divider()
            Button("Refresh") { Task { await model?.refresh() } }
                .keyboardShortcut("r")
                .disabled(model == nil)
            Button("New Branch…") { model?.beginNewBranch() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model == nil)
            Divider()
            Button("Fetch") { model?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(model == nil || model?.remoteOperation != nil)
            Button("Pull") { model?.pull() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(model == nil || model?.remoteOperation != nil)
            Button("Push") { model?.push() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model == nil || model?.remoteOperation != nil)
            Button("Stash Changes…") { model?.showStashSheet = true }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(model?.changes.isEmpty ?? true)
            Button("Optimize Repository") { model?.optimizeRepository() }
                .disabled(model == nil || model?.remoteOperation != nil)
            Button("Show Activity") { model?.showActivity.toggle() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(model == nil)
            Divider()
            Button("Filter History…") {
                model?.sidebarSelection = .history
                model?.focusFilterToken += 1
            }
            .keyboardShortcut("f")
            .disabled(model == nil)
            Divider()
            Button("Working Copy") { model?.sidebarSelection = .workingCopy }
                .keyboardShortcut("1")
                .disabled(model == nil)
            Button("History") { model?.sidebarSelection = .history }
                .keyboardShortcut("2")
                .disabled(model == nil)
        }
    }
}

struct RepoModelKey: FocusedValueKey {
    typealias Value = RepoModel
}

extension FocusedValues {
    var repoModel: RepoModel? {
        get { self[RepoModelKey.self] }
        set { self[RepoModelKey.self] = newValue }
    }
}

/// `GROVE_REPO=/path` or a first CLI argument opens that repository at launch.
@MainActor
enum LaunchOptions {
    private static var pending: URL? = {
        let env = ProcessInfo.processInfo.environment["GROVE_REPO"]
        let arg = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("-") }
        return (env ?? arg).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }()

    static func take() -> URL? {
        defer { pending = nil }
        return pending
    }
}

@MainActor
enum RepositoryPicker {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Git working tree"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum RecentRepositories {
    private static let key = "recentRepositories"

    /// Recent repositories that still exist on disk.
    static func all() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(12)), forKey: key)
        ToolboxRecents.record(url)
    }
}

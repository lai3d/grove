import AppKit
import GroveCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DiffSettings().tabItem { Label("Diffs", systemImage: "plusminus") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Git.pathDefaultsKey) private var gitPath = ""
    @AppStorage("pullMode") private var pullMode = Repository.PullMode.fastForwardOnly.rawValue
    @AppStorage("signOff") private var signOff = false
    @State private var version: String?

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Git binary", text: $gitPath, prompt: Text("Automatic"))
                        .autocorrectionDisabled()
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
                        if panel.runModal() == .OK, let url = panel.url { gitPath = url.path }
                    }
                }
                Text(version.map { "Using \(Git.defaultExecutable().path) — \($0)" } ?? "git not found at that path")
                    .font(.caption)
                    .foregroundStyle(version == nil ? .red : .secondary)
                Text("Automatic picks Homebrew git, then /usr/local/bin, then /usr/bin. New windows use the change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Pull", selection: $pullMode) {
                    Text("Fast-forward only").tag(Repository.PullMode.fastForwardOnly.rawValue)
                    Text("Rebase").tag(Repository.PullMode.rebase.rawValue)
                    Text("Merge").tag(Repository.PullMode.merge.rawValue)
                }
                Toggle("Add Signed-off-by to new commits", isOn: $signOff)
            }
        }
        .formStyle(.grouped)
        .task(id: gitPath) { version = await Git().version() }
    }
}

private struct DiffSettings: View {
    @AppStorage("diffMode") private var mode: DiffMode = .unified
    @AppStorage("diffFontSize") private var fontSize = 12.0

    var body: some View {
        Form {
            Picker("Commit diffs", selection: $mode) {
                Text("Unified").tag(DiffMode.unified)
                Text("Side by side").tag(DiffMode.split)
            }
            LabeledContent("Font size") {
                HStack {
                    Slider(value: $fontSize, in: 9...20, step: 1)
                    Text("\(Int(fontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Text("let preview = \"Grove\" // \(Int(fontSize)) pt")
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

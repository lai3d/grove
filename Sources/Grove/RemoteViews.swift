import GroveCore
import SwiftUI

struct RemoteToolbar: ToolbarContent {
    let model: RepoModel

    var body: some ToolbarContent {
        ToolbarItem {
            if let op = model.remoteOperation {
                RemoteProgress(op: op) { model.cancelRemoteOperation() }
            }
        }
        ToolbarItemGroup {
            let busy = model.remoteOperation != nil || !model.hasRemotes
            Button { model.fetch() } label: {
                Label("Fetch", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            }
            .help("Fetch all remotes (⇧⌘F)")
            .disabled(busy)

            Menu {
                Button("Pull (fast-forward only)") { model.pull(.fastForwardOnly) }
                Button("Pull with Rebase") { model.pull(.rebase) }
                Button("Pull with Merge") { model.pull(.merge) }
                Divider()
                Picker("Default", selection: Binding(get: { model.pullMode }, set: { model.pullMode = $0 })) {
                    Text("Fast-forward only").tag(Repository.PullMode.fastForwardOnly)
                    Text("Rebase").tag(Repository.PullMode.rebase)
                    Text("Merge").tag(Repository.PullMode.merge)
                }
            } label: {
                Label("Pull", systemImage: "arrow.down")
            } primaryAction: {
                model.pull()
            }
            .help(pullHelp)
            .disabled(busy || model.currentBranch == nil)

            Menu {
                Button("Push") { model.push() }
                Button("Force Push (with lease)") { model.push(force: true) }
            } label: {
                Label("Push", systemImage: "arrow.up")
            } primaryAction: {
                model.push()
            }
            .help(pushHelp)
            .disabled(busy || model.currentBranch == nil)
        }
    }

    private var pullHelp: String {
        guard let ref = model.currentRef, ref.upstream != nil else { return "Pull (⇧⌘L)" }
        return "Pull from \(ref.upstream!) (⇧⌘L)" + (ref.track.isEmpty ? "" : " — \(RefRow.trackSummary(ref.track))")
    }

    private var pushHelp: String {
        guard let ref = model.currentRef else { return "Push (⇧⌘P)" }
        guard let up = ref.upstream else { return "Publish \(ref.name) (⇧⌘P)" }
        return "Push to \(up) (⇧⌘P)" + (ref.track.isEmpty ? "" : " — \(RefRow.trackSummary(ref.track))")
    }
}

struct RemoteProgress: View {
    let op: RemoteOperation
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let f = op.fraction {
                ProgressView(value: f).frame(width: 70)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(op.phase.isEmpty ? "\(op.title)…" : "\(op.title): \(op.phase)")
                .font(.callout)
                .lineLimit(1)
                .frame(maxWidth: 220, alignment: .leading)
            Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .help("Cancel")
        }
        .padding(.horizontal, 8)
    }
}

struct ActivityView: View {
    let model: RepoModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Clear") { model.clearActivity() }
                    .buttonStyle(.borderless)
                    .disabled(model.activity.isEmpty)
            }
            .padding(10)
            Divider()
            if model.activity.isEmpty {
                ContentUnavailableView("No Commands Yet", systemImage: "terminal",
                                       description: Text("Every git command Grove runs that changes something shows up here."))
            } else {
                List(model.activity.reversed()) { ActivityRow(entry: $0) }
                    .listStyle(.plain)
            }
        }
    }
}

struct ActivityRow: View {
    let entry: ActivityEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                status
                Text(entry.command)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if let d = entry.duration {
                    Text(d < 1 ? "\(Int(d * 1000)) ms" : String(format: "%.1f s", d))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if expanded, let text = entry.launchError ?? (entry.output.isEmpty ? nil : entry.output) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(entry.succeeded ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                    .padding(.leading, 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .onAppear { if !entry.succeeded && !entry.isRunning { expanded = true } }
        .help(entry.start.formatted(date: .omitted, time: .standard))
    }

    @ViewBuilder private var status: some View {
        if entry.isRunning {
            ProgressView().controlSize(.mini)
        } else if entry.succeeded {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct CredentialSheet: View {
    let prompt: CredentialPrompt
    @State private var answer = ""
    @State private var answered = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let req = prompt.request
        VStack(alignment: .leading, spacing: 12) {
            Label(req.kind == .confirm ? "Confirm" : "Authentication Required",
                  systemImage: req.kind == .confirm ? "questionmark.circle" : "key.fill")
                .font(.headline)
            Text(req.prompt)
                .font(req.prompt.count > 120 ? .system(.callout, design: .monospaced) : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            switch req.kind {
            case .secret:
                SecureField("", text: $answer).textFieldStyle(.roundedBorder).onSubmit { finish(answer) }
            case .text:
                TextField("", text: $answer).textFieldStyle(.roundedBorder).onSubmit { finish(answer) }
            case .confirm:
                EmptyView()
            }
            HStack {
                Spacer()
                if req.kind == .confirm {
                    Button("No", role: .cancel) { finish(req.confirmAnswer(false)) }.keyboardShortcut(.cancelAction)
                    Button("Yes") { finish(req.confirmAnswer(true)) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { finish(nil) }.keyboardShortcut(.cancelAction)
                    Button("OK") { finish(answer) }.keyboardShortcut(.defaultAction)
                }
            }
            if req.kind == .secret {
                Text("HTTPS credentials are saved by git's credential helper (Keychain) once they work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { if !answered { prompt.respond(nil) } }
    }

    private func finish(_ value: String?) {
        answered = true
        prompt.respond(value)
        dismiss()
    }
}

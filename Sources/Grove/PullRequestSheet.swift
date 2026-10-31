import GroveCore
import SwiftUI

/// Asks for a pull / merge request number (or URL) to fetch and check out.
struct PullRequestSheet: View {
    let model: RepoModel
    @State private var input = ""
    @Environment(\.dismiss) private var dismiss

    private var number: Int? { HostedRepo.pullRequestNumber(from: input) }
    private var noun: String { model.hosted?.host == .gitlab ? "Merge Request" : "Pull Request" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check Out \(noun)").font(.headline)
            if let h = model.hosted {
                Text("From \(h.remote) (\(h.web.host() ?? h.host.rawValue)\(h.web.path())). Updates to the request are picked up by checking it out again.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Number or URL, e.g. 123", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit(checkOut)
            if let n = number, let h = model.hosted {
                Text("Fetches into branch “\(h.pullRequestBranch(n))”").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if let h = model.hosted, let n = number {
                    Button("Open on \(h.host.rawValue)") { model.openWeb(h.pullRequest(n)) }
                        .buttonStyle(.link)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Check Out") { checkOut() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(number == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func checkOut() {
        guard let n = number else { return }
        dismiss()
        Task { await model.checkOutPullRequest(n) }
    }
}

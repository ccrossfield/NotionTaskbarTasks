import SwiftUI
import NotionTasksCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tokenField = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch model.state {
            case .needsToken:
                tokenEntry
            case .loading:
                ProgressView("Loading tasks…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            case .loaded(let tasks):
                taskList(tasks)
            case .failed(let message):
                failure(message)
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .task { await model.start() }
    }

    private var header: some View {
        Text("Tasks")
            .font(.headline)
    }

    private var tokenEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a Notion internal integration token to connect. It's stored in your Keychain.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SecureField("ntn_…", text: $tokenField)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .disabled(tokenField.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func taskList(_ tasks: [NotionTask]) -> some View {
        Group {
            if tasks.isEmpty {
                Text("No tasks.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(tasks) { task in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(task.title)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Text(task.status ?? "—")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Try again") { Task { await model.refresh() } }
        }
    }

    private var footer: some View {
        HStack {
            Button("Refresh") { Task { await model.refresh() } }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .font(.callout)
    }

    private func connect() {
        let token = tokenField
        tokenField = ""
        Task { await model.submit(token: token) }
    }
}

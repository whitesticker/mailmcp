import SwiftUI

struct ToolHistoryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.mcpToolHistory.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
        .navigationTitle("Tool history")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") {
                    appState.clearMCPToolHistory()
                }
                .disabled(appState.mcpToolHistory.isEmpty)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No tool calls yet.")
                .foregroundStyle(.secondary)
            Text("When an agent uses MailMCP, each call and its parameters show up here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        let calls = appState.mcpToolHistory
        return List {
            ForEach(calls, id: \.id) { call in
                historyRow(call)
            }
        }
    }

    private func historyRow(_ call: MCPToolCallRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(call.tool)
                    .font(.headline)
                Spacer()
                Text(call.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(call.succeeded ? call.agentName : "\(call.agentName) · failed")
                .font(.caption)
                .foregroundStyle(call.succeeded ? Color.secondary : Color.red)
            Text(call.argumentsJSON == "{}" ? "No parameters" : call.argumentsJSON)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(call.argumentsJSON == "{}" ? Color.secondary : Color.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}

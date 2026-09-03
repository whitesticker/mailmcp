import Charts
import SwiftUI

struct ToolHistoryView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.mcpToolHistory.isEmpty {
                VStack(spacing: 0) {
                    persistControls
                    Divider()
                    emptyState
                }
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

    private var persistControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Save locally", isOn: persistBinding)
            Text(
                appState.persistToolHistory
                    ? "Writes redacted calls to this Mac so a restart does not wipe them."
                    : "Keeps the last 500 calls in memory only. Restart clears the list."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if appState.persistToolHistory {
                Stepper(
                    "Keep \(appState.toolHistoryLimit) calls",
                    value: limitBinding,
                    in: MCPCallLog.minHistoryLimit...MCPCallLog.maxHistoryLimit,
                    step: 50
                )
            }
        }
        .padding(16)
    }

    private var persistBinding: Binding<Bool> {
        Binding(
            get: { appState.persistToolHistory },
            set: { appState.persistToolHistory = $0 }
        )
    }

    private var limitBinding: Binding<Int> {
        Binding(
            get: { appState.toolHistoryLimit },
            set: { appState.toolHistoryLimit = $0 }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No tool calls yet.")
                .foregroundStyle(.secondary)
            Text("When an agent uses MailMCP, totals, charts, and each call show up here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var historyList: some View {
        let calls = appState.mcpToolHistory
        let stats = MCPCallLog.aggregate(calls)
        return List {
            Section("Keep on this Mac") {
                persistControls
                    .listRowInsets(EdgeInsets())
            }
            Section("This session") {
                overview(stats)
                if stats.timeline.count > 1 {
                    timelineChart(stats.timeline)
                }
                if stats.byAgent.count > 1 || stats.byKind.count > 1 {
                    HStack(alignment: .top, spacing: 16) {
                        if !stats.byAgent.isEmpty {
                            agentChart(stats.byAgent)
                        }
                        if !stats.byKind.isEmpty {
                            kindChart(stats.byKind)
                        }
                    }
                } else if let only = stats.byAgent.first {
                    LabeledContent("Agent", value: "\(only.name) · \(only.count)")
                }
            }
            if !stats.byTool.isEmpty {
                Section("Calls by tool") {
                    toolChart(stats.byTool)
                }
            }
            Section("Recent calls") {
                ForEach(calls) { call in
                    historyRow(call)
                }
            }
        }
    }

    private func overview(_ stats: MCPToolHistoryAggregate) -> some View {
        HStack(spacing: 24) {
            stat("Calls", "\(stats.total)")
            stat("Agents", "\(stats.byAgent.count)")
            stat("Tools", "\(stats.byTool.count)")
            stat("Failed", "\(stats.failed)")
                .foregroundStyle(stats.failed > 0 ? Color.red : Color.secondary)
        }
        .padding(.vertical, 4)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func timelineChart(_ points: [MCPHistoryPoint]) -> some View {
        Chart(points) { point in
            LineMark(
                x: .value("Time", point.date),
                y: .value("Calls", point.count)
            )
            AreaMark(
                x: .value("Time", point.date),
                y: .value("Calls", point.count)
            )
            .opacity(0.12)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4))
        }
        .frame(height: 120)
        .padding(.vertical, 4)
    }

    private func agentChart(_ buckets: [MCPHistoryBucket]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By agent")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Calls", bucket.count),
                    y: .value("Agent", bucket.name)
                )
            }
            .frame(minHeight: CGFloat(max(buckets.count, 1) * 28), maxHeight: 160)
        }
    }

    private func kindChart(_ buckets: [MCPHistoryBucket]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By kind")
                .font(.caption)
                .foregroundStyle(.secondary)
            Chart(buckets) { bucket in
                SectorMark(
                    angle: .value("Calls", bucket.count),
                    innerRadius: .ratio(0.52)
                )
                .foregroundStyle(by: .value("Kind", bucket.name))
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 160)
        }
    }

    private func toolChart(_ buckets: [MCPHistoryBucket]) -> some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Calls", bucket.count),
                y: .value("Tool", bucket.name)
            )
        }
        .frame(height: CGFloat(max(buckets.count, 1) * 26 + 8))
        .padding(.vertical, 4)
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

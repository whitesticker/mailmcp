import AppKit
import Charts
import SwiftUI

private enum CallStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case succeeded = "Succeeded"
    case failed = "Failed"

    var id: String { rawValue }
}

private enum BreakdownTab: String, CaseIterable, Identifiable {
    case byTool = "By Tool"
    case byMailbox = "By Mailbox"

    var id: String { rawValue }
}

@MainActor
final class RecentCallsWindowController {
    static let shared = RecentCallsWindowController()

    private var window: NSWindow?

    func show(appState: AppState) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = RecentCallsPopoutView()
            .environmentObject(appState)
        let hosting = NSHostingController(rootView: contentView)

        let win = NSWindow(contentViewController: hosting)
        win.identifier = NSUserInterfaceItemIdentifier("recent-calls")
        win.title = "Recent Tool Calls"
        win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 820, height: 600))
        win.contentMinSize = NSSize(width: 640, height: 400)

        if let mainWin = MailMCPAppDelegate.mainWindow() {
            let mainFrame = mainWin.frame
            let origin = NSPoint(
                x: mainFrame.midX - 410 + 36,
                y: mainFrame.midY - 300 - 24
            )
            win.setFrameOrigin(origin)
        } else {
            win.center()
        }

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }
}

struct ToolHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var breakdownTab: BreakdownTab = .byTool
    @State private var timeRange: ToolHistoryTimeRange = .all

    var body: some View {
        let allCalls = appState.mcpToolHistory
        let filteredCalls = timeRange.filter(allCalls)
        let stats = MCPCallLog.aggregate(filteredCalls, accounts: appState.accounts)

        VStack(spacing: 0) {
            if allCalls.isEmpty {
                persistControlsBar
                Divider()
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        headerControlCard(totalAllTime: allCalls.count, filteredCount: filteredCalls.count)

                        kpiGrid(stats)

                        if !stats.timeline.isEmpty {
                            timelineCard(stats.timeline, total: stats.total)
                        }

                        HStack(alignment: .top, spacing: 16) {
                            breakdownCard(stats)

                            VStack(spacing: 16) {
                                if !stats.byKind.isEmpty {
                                    kindDonutCard(stats.byKind, total: stats.total)
                                }
                                if !stats.byAgent.isEmpty {
                                    agentBreakdownCard(stats.byAgent, total: stats.total)
                                }
                            }
                            .frame(minWidth: 240, maxWidth: 300)
                        }
                    }
                    .padding(18)
                }
            }
        }
        .navigationTitle("Tool history")
    }

    // MARK: - Persistence & Time Filter Card

    private var persistControlsBar: some View {
        persistControlsContent
            .padding(16)
    }

    private func headerControlCard(totalAllTime: Int, filteredCount: Int) -> some View {
        VStack(spacing: 12) {
            persistControlsContent
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    timeRangeLabel
                    timeRangePicker
                    Spacer(minLength: 8)
                    rangeSummary(totalAllTime: totalAllTime, filteredCount: filteredCount)
                    historyButtons
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        timeRangeLabel
                        timeRangePicker
                    }
                    HStack(spacing: 12) {
                        rangeSummary(totalAllTime: totalAllTime, filteredCount: filteredCount)
                        Spacer(minLength: 8)
                        historyButtons
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    timeRangePicker
                    HStack(spacing: 12) {
                        rangeSummary(totalAllTime: totalAllTime, filteredCount: filteredCount)
                        Spacer(minLength: 8)
                        historyButtons
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var timeRangeLabel: some View {
        Label("Time range", systemImage: "calendar.badge.clock")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var timeRangePicker: some View {
        Picker("Time range", selection: $timeRange) {
            ForEach(ToolHistoryTimeRange.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func rangeSummary(totalAllTime: Int, filteredCount: Int) -> some View {
        if timeRange != .all {
            Text("Showing \(filteredCount) of \(totalAllTime) calls")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder
    private var historyButtons: some View {
        Button("Recent Calls…") {
            RecentCallsWindowController.shared.show(appState: appState)
        }
        .fixedSize()
        .help("Open the list of individual tool calls")
        Button("Clear", role: .destructive) {
            appState.clearMCPToolHistory()
        }
        .fixedSize()
        .help("Delete all recorded tool calls")
    }

    private var persistControlsContent: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Save tool history on this Mac", isOn: persistBinding)
                    .font(.subheadline.weight(.medium))
                Text(
                    appState.persistToolHistory
                        ? "Writes redacted tool calls to disk so a restart keeps your charts and logs."
                        : "In-memory only (up to 500 calls). Quitting MailMCP clears the log."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if appState.persistToolHistory {
                Stepper(
                    "Keep \(appState.toolHistoryLimit)",
                    value: limitBinding,
                    in: MCPCallLog.minHistoryLimit...MCPCallLog.maxHistoryLimit,
                    step: 50
                )
                .font(.caption.monospacedDigit())
            }
        }
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

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 64, height: 64)
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text("No tool calls recorded yet")
                .font(.headline)
            Text("When an AI agent calls MailMCP tools, live activity charts, tool breakdowns, and recent call logs will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - KPI Summary Cards

    private func kpiGrid(_ stats: MCPToolHistoryAggregate) -> some View {
        let successCount = max(0, stats.total - stats.failed)
        let successRate = stats.total > 0 ? Int(round((Double(successCount) / Double(stats.total)) * 100)) : 100

        return HStack(spacing: 12) {
            kpiCard(
                title: "Total Calls",
                value: "\(stats.total)",
                subtitle: stats.timeline.last.map { "Latest \($0.date.formatted(date: .omitted, time: .shortened))" } ?? "This period",
                icon: "bolt.horizontal.fill",
                tint: .blue
            )
            kpiCard(
                title: "Success Rate",
                value: "\(successRate)%",
                subtitle: stats.failed == 0 ? "All calls succeeded" : "\(stats.failed) failed",
                icon: stats.failed == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                tint: stats.failed == 0 ? .green : .orange
            )
            kpiCard(
                title: "Active Agents",
                value: "\(stats.byAgent.count)",
                subtitle: stats.byAgent.first?.name ?? "None",
                icon: "cpu.fill",
                tint: .purple
            )
            kpiCard(
                title: "Mailboxes Touched",
                value: "\(stats.byMailbox.count)",
                subtitle: stats.byMailbox.first.map { mailboxDisplayLabel($0.name) } ?? "—",
                icon: "envelope.fill",
                tint: .teal
            )
        }
    }

    private func kpiCard(title: String, value: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 24, height: 24)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded).monospacedDigit())
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Activity Over Time Chart

    private func timelineCard(_ points: [MCPHistoryPoint], total: Int) -> some View {
        let peak = points.map(\.count).max() ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Call Activity Over Time")
                        .font(.subheadline.weight(.semibold))
                    Text("Volume of agent MCP requests across time buckets")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if peak > 0 {
                    Text("Peak: \(peak) calls")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
            }

            Chart(points) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value("Calls", point.count)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.32),
                            Color.accentColor.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.date),
                    y: .value("Calls", point.count)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Color.accentColor)

                if point.count > 0 {
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Calls", point.count)
                    )
                    .symbolSize(point.failed > 0 ? 36 : 22)
                    .foregroundStyle(point.failed > 0 ? Color.orange : Color.accentColor)
                }
            }
            .chartYScale(domain: 0...max(peak + 1, 3))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.primary.opacity(0.10))
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color.primary.opacity(0.10))
                    AxisValueLabel()
                        .font(.caption2.monospacedDigit())
                }
            }
            .frame(height: 140)
            .padding(.top, 4)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    // MARK: - Calls by Tool / Calls by Mailbox Card

    private func breakdownCard(_ stats: MCPToolHistoryAggregate) -> some View {
        let buckets = breakdownTab == .byTool ? stats.byTool : stats.byMailbox
        let maxCount = max(buckets.map(\.count).max() ?? 1, 1)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(breakdownTab == .byTool ? "Calls by Tool" : "Calls by Mailbox")
                        .font(.subheadline.weight(.semibold))
                    Text(breakdownTab == .byTool ? "Most frequently invoked MCP tools" : "Mailboxes queried or modified by agents")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Breakdown", selection: $breakdownTab) {
                    ForEach(BreakdownTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
            }

            if buckets.isEmpty {
                Text(breakdownTab == .byTool ? "No tool calls in this period." : "No mailbox-specific calls in this period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                VStack(spacing: 9) {
                    ForEach(buckets) { bucket in
                        let ratio = Double(bucket.count) / Double(maxCount)
                        let displayLabel = breakdownTab == .byMailbox
                            ? mailboxDisplayLabel(bucket.name)
                            : bucket.name

                        HStack(spacing: 10) {
                            Text(displayLabel)
                                .font(breakdownTab == .byTool ? .system(.caption, design: .monospaced) : .caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: breakdownTab == .byMailbox ? 165 : 128, alignment: .leading)
                                .help(bucket.name)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.07))
                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: bucket.failed > 0
                                                    ? [Color.accentColor, Color.orange]
                                                    : (breakdownTab == .byMailbox
                                                        ? [Color.teal, Color.accentColor]
                                                        : [Color.accentColor, Color.cyan.opacity(0.85)]),
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(6, geo.size.width * ratio))
                                }
                            }
                            .frame(height: 8)

                            HStack(spacing: 4) {
                                Text("\(bucket.count)")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if bucket.failed > 0 {
                                    Text("(\(bucket.failed) err)")
                                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                                        .foregroundStyle(.red)
                                }
                            }
                            .frame(minWidth: 68, alignment: .trailing)
                        }
                        .frame(height: 18)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func mailboxDisplayLabel(_ emailKey: String) -> String {
        if let account = appState.accounts.first(where: { $0.email.caseInsensitiveCompare(emailKey) == .orderedSame }) {
            if !account.displayName.isEmpty && account.displayName.caseInsensitiveCompare(account.email) != .orderedSame {
                return "\(account.displayName) (\(account.email))"
            }
            return account.email
        }
        return emailKey
    }

    // MARK: - Category Donut Chart & Agent Breakdown

    private func kindDonutCard(_ buckets: [MCPHistoryBucket], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By Permission Scope")
                .font(.subheadline.weight(.semibold))

            ZStack {
                Chart(buckets) { bucket in
                    SectorMark(
                        angle: .value("Calls", bucket.count),
                        innerRadius: .ratio(0.64),
                        angularInset: 2.0
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Kind", bucket.name))
                }
                .chartForegroundStyleScale(
                    domain: buckets.map(\.name),
                    range: buckets.map { ToolHistoryPalette.colorForKind($0.name) }
                )
                .chartLegend(position: .bottom, alignment: .center, spacing: 6)
                .frame(height: 150)

                VStack(spacing: 1) {
                    Text("\(total)")
                        .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    Text("calls")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .offset(y: -12)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func agentBreakdownCard(_ buckets: [MCPHistoryBucket], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("By Agent")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 9) {
                ForEach(buckets) { bucket in
                    let ratio = total > 0 ? Double(bucket.count) / Double(total) : 0
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(bucket.name, systemImage: "sparkles")
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(bucket.count) (\(Int(round(ratio * 100)))%)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.primary.opacity(0.08))
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [.purple, .accentColor],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: max(6, geo.size.width * ratio))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }
}

// MARK: - Pop-Out Window View for Recent Tool Calls

struct RecentCallsPopoutView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var statusFilter: CallStatusFilter = .all
    @State private var timeRange: ToolHistoryTimeRange = .all
    @State private var selectedTool: String = "__all__"
    @State private var selectedMailbox: String = "__all__"
    @State private var expandedCallIDs: Set<UUID> = []
    @State private var copiedCallID: UUID?

    var body: some View {
        let allCalls = appState.mcpToolHistory
        let availableTools = Array(Set(allCalls.map(\.tool))).sorted()
        let availableMailboxes = collectAvailableMailboxes(allCalls)
        let filtered = filteredCalls(allCalls)

        VStack(spacing: 0) {
            // Header & Filter Bar
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Filter by tool, mailbox, agent, or argument…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.subheadline)
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )

                    Picker("Mailbox", selection: $selectedMailbox) {
                        Text("All mailboxes").tag("__all__")
                        Divider()
                        ForEach(availableMailboxes, id: \.self) { email in
                            Text(mailboxDisplayLabel(email)).tag(email)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)

                    Picker("Tool", selection: $selectedTool) {
                        Text("All tools").tag("__all__")
                        Divider()
                        ForEach(availableTools, id: \.self) { tool in
                            Text(tool).tag(tool)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        filterPickers
                        Spacer(minLength: 8)
                        resultSummary(filtered: filtered, total: allCalls.count)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            filterPickers
                        }
                        HStack(spacing: 12) {
                            Spacer(minLength: 0)
                            resultSummary(filtered: filtered, total: allCalls.count)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        timePicker
                        HStack(spacing: 12) {
                            statusPicker
                            Spacer(minLength: 8)
                            resultSummary(filtered: filtered, total: allCalls.count)
                        }
                    }
                }
            }
            .padding(14)
            .background(.bar)

            Divider()

            if filtered.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    Text(allCalls.isEmpty ? "No recorded calls." : "No calls match your filter.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filtered) { call in
                            recentCallCard(call)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    @ViewBuilder
    private var filterPickers: some View {
        timePicker
        statusPicker
    }

    private var timePicker: some View {
        Picker("Time", selection: $timeRange) {
            ForEach(ToolHistoryTimeRange.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var statusPicker: some View {
        Picker("Status", selection: $statusFilter) {
            ForEach(CallStatusFilter.allCases) { item in
                Text(item.rawValue).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func resultSummary(filtered: [MCPToolCallRecord], total: Int) -> some View {
        Text("Showing \(filtered.count) of \(total)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()

        if !filtered.isEmpty {
            Button(expandedCallIDs.isEmpty ? "Expand JSON" : "Collapse JSON") {
                if expandedCallIDs.isEmpty {
                    for item in filtered.prefix(50) {
                        expandedCallIDs.insert(item.id)
                    }
                } else {
                    expandedCallIDs.removeAll()
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .fixedSize()
        }
    }

    private func recentCallCard(_ call: MCPToolCallRecord) -> some View {
        let isExpanded = expandedCallIDs.contains(call.id)
        let hasArgs = call.argumentsJSON != "{}" && !call.argumentsJSON.isEmpty
        let audienceTitle = MCPToolCatalog.audience(forTool: call.tool)?.title ?? "Other"
        let scopeColor = ToolHistoryPalette.colorForKind(audienceTitle)
        let callMailboxes = MCPCallLog.mailboxes(for: call, accounts: appState.accounts)
        let agentLabel = MCPCallLog.displayName(clientName: call.agentName)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(call.succeeded ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(call.tool)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))

                Text(audienceTitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(scopeColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(scopeColor.opacity(0.14), in: Capsule())

                Text(agentLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())

                if let firstBox = callMailboxes.first {
                    Text(callMailboxes.count > 1 ? "\(mailboxDisplayLabel(firstBox)) +\(callMailboxes.count - 1)" : mailboxDisplayLabel(firstBox))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.teal)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.teal.opacity(0.12), in: Capsule())
                        .lineLimit(1)
                }

                if !call.succeeded {
                    Text("Failed")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red, in: Capsule())
                }

                Spacer()

                Text(call.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                if hasArgs {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(call.argumentsJSON, forType: .string)
                        copiedCallID = call.id
                    } label: {
                        Image(systemName: copiedCallID == call.id ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy arguments JSON")

                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            if isExpanded {
                                expandedCallIDs.remove(call.id)
                            } else {
                                expandedCallIDs.insert(call.id)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(isExpanded ? "Hide JSON" : "Args")
                                .font(.caption2.weight(.medium))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            if hasArgs {
                if isExpanded {
                    Text(call.argumentsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text(compactSingleLineJSON(call.argumentsJSON))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text("No parameters")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(call.succeeded ? Color.primary.opacity(0.06) : Color.red.opacity(0.35), lineWidth: 1)
        )
    }

    private func collectAvailableMailboxes(_ calls: [MCPToolCallRecord]) -> [String] {
        var set = Set<String>()
        for acc in appState.accounts {
            set.insert(acc.email.lowercased())
        }
        for call in calls {
            for box in MCPCallLog.mailboxes(for: call, accounts: appState.accounts) {
                set.insert(box.lowercased())
            }
        }
        return set.sorted()
    }

    private func mailboxDisplayLabel(_ emailKey: String) -> String {
        if let account = appState.accounts.first(where: { $0.email.caseInsensitiveCompare(emailKey) == .orderedSame }) {
            if !account.displayName.isEmpty && account.displayName.caseInsensitiveCompare(account.email) != .orderedSame {
                return "\(account.displayName) (\(account.email))"
            }
            return account.email
        }
        return emailKey
    }

    private func filteredCalls(_ calls: [MCPToolCallRecord]) -> [MCPToolCallRecord] {
        let timeFiltered = timeRange.filter(calls)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return timeFiltered.filter { call in
            if selectedTool != "__all__" && call.tool != selectedTool {
                return false
            }
            if selectedMailbox != "__all__" {
                let boxes = MCPCallLog.mailboxes(for: call, accounts: appState.accounts)
                if !boxes.contains(where: { $0.caseInsensitiveCompare(selectedMailbox) == .orderedSame }) {
                    return false
                }
            }
            switch statusFilter {
            case .all: break
            case .succeeded: if !call.succeeded { return false }
            case .failed: if call.succeeded { return false }
            }
            guard !needle.isEmpty else { return true }
            return call.tool.lowercased().contains(needle)
                || MCPCallLog.displayName(clientName: call.agentName).lowercased().contains(needle)
                || call.argumentsJSON.lowercased().contains(needle)
        }
    }

    private func compactSingleLineJSON(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ToolHistoryPalette {
    static func colorForKind(_ kind: String) -> Color {
        switch kind {
        case "Read only": return .blue
        case "Add to mailbox": return .teal
        case "Alter mailbox": return .orange
        case "Reaches others": return .purple
        default: return .gray
        }
    }
}

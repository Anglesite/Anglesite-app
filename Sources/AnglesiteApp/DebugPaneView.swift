import SwiftUI
import AnglesiteCore

/// Live tail of every subprocess line that lands in `LogCenter.shared`.
///
/// Subscribes once per appearance, accumulates into local state, and offers filter chips so a
/// developer hunting a bug can isolate (say) the `astro` source's stderr without scrolling
/// through MCP traffic. Auto-scroll defaults on but can be turned off when copying text.
struct DebugPaneView: View {
    @State private var lines: [LogCenter.LogLine] = []
    @State private var knownSources: Set<String> = []
    @State private var sourceFilter: String = "All"
    @State private var streamFilter: StreamFilter = .all
    @State private var autoScroll: Bool = true
    @State private var subscriberTask: Task<Void, Never>?

    private let center: LogCenter

    init(center: LogCenter = .shared) {
        self.center = center
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleLines) { line in
                            row(for: line).id(line.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: visibleLines.last?.id) { _, newID in
                    guard autoScroll, let newID else { return }
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .task { await startStreaming() }
        .onDisappear { subscriberTask?.cancel() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $sourceFilter) {
                Text("All").tag("All")
                ForEach(Array(knownSources).sorted(), id: \.self) { src in
                    Text(src).tag(src)
                }
            }
            .frame(maxWidth: 220)

            Picker("Stream", selection: $streamFilter) {
                ForEach(StreamFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)

            Spacer()

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.switch)

            Button("Clear") { lines.removeAll() }
            Button("Copy") { copyVisibleToClipboard() }
        }
    }

    private func row(for line: LogCenter.LogLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: line.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 88, alignment: .leading)
            Text(line.source)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
                .lineLimit(1)
            Image(systemName: line.stream == .stderr ? "exclamationmark.bubble" : "text.bubble")
                .foregroundStyle(line.stream == .stderr ? .orange : .secondary)
                .imageScale(.small)
            Text(line.text)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var visibleLines: [LogCenter.LogLine] {
        lines.filter { line in
            if sourceFilter != "All" && line.source != sourceFilter { return false }
            switch streamFilter {
            case .all: return true
            case .stdout: return line.stream == .stdout
            case .stderr: return line.stream == .stderr
            }
        }
    }

    private func startStreaming() async {
        // Replay buffered history first so opening the pane mid-session shows context.
        let history = await center.snapshot()
        lines = history
        for line in history { knownSources.insert(line.source) }

        let subscription = await center.subscribe()
        let task = Task { @MainActor in
            for await line in subscription.stream {
                if Task.isCancelled { break }
                lines.append(line)
                if lines.count > 5000 { lines.removeFirst(lines.count - 5000) }
                knownSources.insert(line.source)
            }
        }
        subscriberTask = task
        // Wait so the task is cleaned up when this scope ends; never returns under normal use.
        _ = await task.value
    }

    private func copyVisibleToClipboard() {
        let formatter = Self.timeFormatter
        let text = visibleLines
            .map { "\(formatter.string(from: $0.timestamp))  [\($0.source)/\($0.stream.rawValue)]  \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    enum StreamFilter: String, CaseIterable, Hashable {
        case all, stdout, stderr
        var label: String {
            switch self {
            case .all: return "Both"
            case .stdout: return "Out"
            case .stderr: return "Err"
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

#Preview {
    DebugPaneView()
}

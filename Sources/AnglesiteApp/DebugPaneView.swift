import SwiftUI
import UniformTypeIdentifiers
import AnglesiteCore

/// Live tail of every subprocess line that lands in `LogCenter.shared`.
///
/// Subscribes once per appearance, accumulates into local state, and offers source/stream filter
/// chips plus a free-text search so a developer hunting a bug can isolate the lines that matter.
/// `Pause` freezes the displayed rows (the underlying buffer keeps filling, so nothing is lost);
/// `Save…` and `Copy` export whatever's currently visible.
struct DebugPaneView: View {
    @State private var lines: [LogCenter.LogLine] = []
    @State private var frozenLines: [LogCenter.LogLine]?  // non-nil while paused: the snapshot to show
    @State private var knownSources: Set<String> = []
    @State private var sourceFilter: String = allSourcesTag
    @State private var streamFilter: StreamFilter = .all
    @State private var searchQuery: String = ""
    @State private var autoScroll: Bool = true
    @State private var subscriberTask: Task<Void, Never>?

    private static let allSourcesTag = "All"
    private let center: LogCenter

    init(center: LogCenter = .shared) {
        self.center = center
    }

    private var isPaused: Bool { frozenLines != nil }

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
                    guard autoScroll, !isPaused, let newID else { return }
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo(newID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 400)
        .task { await startStreaming() }
        .onDisappear { subscriberTask?.cancel() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $sourceFilter) {
                Text("All").tag(Self.allSourcesTag)
                ForEach(Array(knownSources).sorted(), id: \.self) { src in
                    Text(src).tag(src)
                }
            }
            .frame(maxWidth: 200)

            Picker("Stream", selection: $streamFilter) {
                ForEach(StreamFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            TextField("Search", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, maxWidth: 240)

            Spacer()

            Toggle("Pause", isOn: Binding(
                get: { isPaused },
                set: { frozenLines = $0 ? lines : nil }
            ))
            .toggleStyle(.switch)

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.switch)
                .disabled(isPaused)

            Button("Clear") {
                lines.removeAll()
                frozenLines = nil
            }
            Button("Copy") { copyVisibleToClipboard() }
            Button("Save…") { saveVisibleToFile() }
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
        (frozenLines ?? lines).filtered(
            source: sourceFilter == Self.allSourcesTag ? nil : sourceFilter,
            stream: streamFilter.logStream,
            query: searchQuery
        )
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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleLines.exportText(), forType: .string)
    }

    private func saveVisibleToFile() {
        let panel = NSSavePanel()
        panel.title = "Save Process Log"
        panel.nameFieldStringValue = "anglesite-\(Self.fileStampFormatter.string(from: Date())).log"
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText, .plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? visibleLines.exportText().write(to: url, atomically: true, encoding: .utf8)
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
        var logStream: LogCenter.Stream? {
            switch self {
            case .all: return nil
            case .stdout: return .stdout
            case .stderr: return .stderr
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let fileStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

#Preview {
    DebugPaneView()
}

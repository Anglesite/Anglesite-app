import SwiftUI
import AnglesiteCore

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Anglesite")
                .font(.largeTitle)
                .fontWeight(.semibold)
            Text("Phase 0 scaffold")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(BuildInfo.summary)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}

#Preview {
    ContentView()
}

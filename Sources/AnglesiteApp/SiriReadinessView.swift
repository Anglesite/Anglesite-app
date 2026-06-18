import SwiftUI
import AnglesiteCore
import AnglesiteIntents

/// One capability row: status glyph + title + concrete detail + optional remediation.
struct ReadinessRow: View {
    let finding: ReadinessFinding

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: glyph)
                .foregroundStyle(tint)
                .accessibilityLabel(accessibilityStatus)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title).font(.body)
                Text(finding.detail).font(.caption).foregroundStyle(.secondary)
                if let remediation = finding.remediation {
                    Text(remediation).font(.caption).foregroundStyle(.blue)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var glyph: String {
        switch finding.level {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failure: return "xmark.octagon.fill"
        case .unsupported: return "minus.circle"
        }
    }

    private var tint: Color {
        switch finding.level {
        case .ok: return .green
        case .warning: return .orange
        case .failure: return .red
        case .unsupported: return .secondary
        }
    }

    private var accessibilityStatus: String {
        switch finding.level {
        case .ok: return "OK"
        case .warning: return "Warning"
        case .failure: return "Failure"
        case .unsupported: return "Not available"
        }
    }
}

/// Renders a readiness model: the findings list, a re-check button, and a last-checked stamp.
/// Drives an initial check on appear. Reused by Settings (system) and the per-window sheet.
struct SiriReadinessList: View {
    let model: SiriReadinessModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.findings) { finding in
                ReadinessRow(finding: finding)
            }
            HStack {
                Button("Re-check") { model.recheck() }
                    .disabled(model.isChecking)
                if model.isChecking {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let checked = model.lastChecked {
                    Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { if model.findings.isEmpty { model.recheck() } }
    }
}

/// Settings ▸ Siri AI. System-wide capabilities only; per-site readiness lives in each site window.
struct SiriReadinessSettingsView: View {
    @State private var model = SiriReadinessModel(probes: SiriReadinessProbes.system())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Whether this Mac can run Siri-driven Anglesite workflows. Per-site readiness is in each site window (Site ▸ Siri AI Readiness).")
                    .font(.caption).foregroundStyle(.secondary)
                SiriReadinessList(model: model)
            }
            .padding()
        }
    }
}

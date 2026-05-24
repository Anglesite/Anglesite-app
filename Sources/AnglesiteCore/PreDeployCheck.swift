import Foundation

/// Runs the bundled plugin's pre-deploy scans against a site directory and
/// returns a structured outcome the app can render.
///
/// The four mandatory blockers (PII, exposed tokens, third-party scripts,
/// Keystatic admin routes) come from `template/scripts/pre-deploy-check.ts`
/// invoked with `--json`. The JSON contract is owned by the plugin — this
/// actor is just a typed shell around `JSONDecoder` and a script invocation.
///
/// `PreDeployCheck` is intentionally minimal: no Cloudflare token resolution,
/// no `npm run build`, no UI. Callers (today: `DeployCommand`) decide what to
/// do with the `Outcome`. The build step lands with the deploy-flow polish in
/// #22; this actor presumes `dist/` already exists and surfaces a `.error`
/// outcome when it does not.
public actor PreDeployCheck {
    public enum Outcome: Sendable, Equatable {
        case passed(warnings: [ScanWarning])
        case blocked(failures: [ScanFailure], warnings: [ScanWarning])
        /// Script error — couldn't run the scan at all (missing tsx, missing
        /// dist/, malformed JSON). Distinct from `.blocked` so callers can
        /// surface the right remediation.
        case error(reason: String)
    }

    public struct ScanFailure: Sendable, Equatable, Codable {
        public enum Category: String, Sendable, Codable {
            case piiEmail = "pii-email"
            case piiPhone = "pii-phone"
            case exposedToken = "exposed-token"
            case thirdPartyScript = "third-party-script"
            case keystaticRoute = "keystatic-route"
        }
        public let category: Category
        /// Repo-relative path of the file where the issue was found, when known.
        public let file: String?
        public let detail: String
        public let remediation: String

        public init(category: Category, file: String?, detail: String, remediation: String) {
            self.category = category
            self.file = file
            self.detail = detail
            self.remediation = remediation
        }
    }

    public struct ScanWarning: Sendable, Equatable, Codable {
        public enum Category: String, Sendable, Codable {
            case missingOgImage = "missing-og-image"
            case maintenanceOverdue = "maintenance-overdue"
            case seoCritical = "seo-critical"
            case seoWarning = "seo-warning"
        }
        public let category: Category
        public let detail: String
        public let remediation: String

        public init(category: Category, detail: String, remediation: String) {
            self.category = category
            self.detail = detail
            self.remediation = remediation
        }
    }

    /// Spawns the scan script and returns its stdout + exit code. Tests inject
    /// a fake; the default invoker shells out to `npx tsx scripts/pre-deploy-check.ts --json`
    /// with `siteDirectory` as cwd.
    public typealias ScriptInvoker = @Sendable (_ siteDirectory: URL) async throws -> (stdout: String, exitCode: Int32)

    private let invoke: ScriptInvoker

    public init(invoke: @escaping ScriptInvoker) {
        self.invoke = invoke
    }

    public func check(siteID: String, siteDirectory: URL) async -> Outcome {
        let result: (stdout: String, exitCode: Int32)
        do {
            result = try await invoke(siteDirectory)
        } catch {
            return .error(reason: "couldn't run pre-deploy scan: \(error)")
        }

        struct RawReport: Decodable {
            let ok: Bool
            let failures: [ScanFailure]
            let warnings: [ScanWarning]
        }

        let stdoutData = Data(result.stdout.utf8)
        let report: RawReport
        do {
            report = try JSONDecoder().decode(RawReport.self, from: stdoutData)
        } catch {
            // No parseable JSON — the script most likely errored out. Exit
            // code 1 with no JSON typically means missing dist/ or missing tsx.
            return .error(reason: result.exitCode == 0
                ? "pre-deploy scan emitted no JSON (exit 0) — is the site's scripts/pre-deploy-check.ts up to date?"
                : "pre-deploy scan failed (exit \(result.exitCode)) — run `npm run build` and try again, or run `/anglesite:update` if the script is outdated")
        }

        if report.ok {
            return .passed(warnings: report.warnings)
        }
        return .blocked(failures: report.failures, warnings: report.warnings)
    }
}

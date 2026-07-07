import Foundation

/// Applies an accepted dependency-sync update (spec §6): rewrites `package.json`'s
/// version ranges, deletes the now-stale `package-lock.json` (so the next preview
/// boot's existing `hydrate.sh` regenerates one via its normal `npm install` path —
/// no new container-exec machinery), refreshes the baseline, and bumps the
/// `ANGLESITE_VERSION` stamp. The lockfile delete, baseline save, and version bump
/// are best-effort (`try?`) once the package.json rewrite itself has succeeded —
/// none of them are things the user's file-open flow should hard-fail on.
public enum DependencySyncApplier {
    public enum ApplyError: Error, Equatable {
        case readFailed
        case writeFailed
    }

    public static func apply(
        _ offers: [DependencyUpdateOffer],
        sourceDirectory: URL,
        configDirectory: URL,
        runningAppVersion: String
    ) throws {
        let packageJSONURL = sourceDirectory.appendingPathComponent("package.json")
        guard let originalText = try? String(contentsOf: packageJSONURL, encoding: .utf8) else {
            throw ApplyError.readFailed
        }
        let updatedText = PackageJSONDependencies.apply(offers, to: originalText)
        do {
            try updatedText.write(to: packageJSONURL, atomically: true, encoding: .utf8)
        } catch {
            throw ApplyError.writeFailed
        }

        try? FileManager.default.removeItem(at: sourceDirectory.appendingPathComponent("package-lock.json"))

        var newBaseline = DependencyBaseline.load(from: configDirectory) ?? [:]
        for offer in offers { newBaseline[offer.name] = offer.offeredRange }
        try? DependencyBaseline.save(newBaseline, to: configDirectory)

        let siteConfigURL = sourceDirectory.appendingPathComponent(".site-config")
        let existingConfig = (try? String(contentsOf: siteConfigURL, encoding: .utf8)) ?? ""
        let updatedConfig = SiteConfigFile.upsert([("ANGLESITE_VERSION", runningAppVersion)], into: existingConfig)
        try? updatedConfig.write(to: siteConfigURL, atomically: true, encoding: .utf8)
    }
}

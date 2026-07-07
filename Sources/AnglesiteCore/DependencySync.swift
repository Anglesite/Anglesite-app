/// One offered version-range bump for a single package.
public struct DependencyUpdateOffer: Sendable, Equatable {
    public let name: String
    public let currentRange: String
    public let offeredRange: String

    public init(name: String, currentRange: String, offeredRange: String) {
        self.name = name
        self.currentRange = currentRange
        self.offeredRange = offeredRange
    }
}

/// Three-way comparison between a site's dependencies, an optional scaffold-time
/// baseline snapshot, and the app's current bundled template (spec §3). Only ever
/// offers a version bump for a package present in both the site and the template —
/// never adds or removes a package name.
public enum DependencySync {
    public static func diff(
        site: [String: String],
        baseline: [String: String]?,
        template: [String: String]
    ) -> [DependencyUpdateOffer] {
        var offers: [DependencyUpdateOffer] = []
        for (name, templateRange) in template.sorted(by: { $0.key < $1.key }) {
            guard let siteRange = site[name] else { continue }
            guard DependencyVersionComparator.isNewer(templateRange, than: siteRange) == true else { continue }
            if let baseline {
                // 3-way case: only offer when the site never touched this package
                // since it was scaffolded (its range still matches the baseline).
                guard let baselineRange = baseline[name], baselineRange == siteRange else { continue }
            }
            // else: no baseline at all -> legacy direct-diff fallback (spec §3).
            offers.append(DependencyUpdateOffer(name: name, currentRange: siteRange, offeredRange: templateRange))
        }
        return offers
    }
}

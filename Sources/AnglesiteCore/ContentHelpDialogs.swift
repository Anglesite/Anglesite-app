import Foundation

/// Pure dialog/summary strings shared by the content-help App Intents and GUI (#465), kept in
/// Core (pattern: `IntegrationDialogs`) so CI unit-tests them without the AppIntents runtime.
public enum ContentHelpDialogs {
    public static func copyReview(findingCount: Int, pageCount: Int, skippedCount: Int, siteName: String) -> String {
        var d: String
        if findingCount == 0 {
            d = "I found no copy issues across \(pageCount) page\(pageCount == 1 ? "" : "s") on \(siteName)."
        } else {
            d = "I found \(findingCount) copy suggestion\(findingCount == 1 ? "" : "s") across \(pageCount) page\(pageCount == 1 ? "" : "s") on \(siteName). Open Review Copy in Anglesite to apply them."
        }
        if skippedCount > 0 { d += " \(skippedCount) page\(skippedCount == 1 ? "" : "s") couldn't be reviewed." }
        return d
    }

    public static func assistantUnavailable(feature: String) -> String {
        "\(feature) needs Apple Intelligence, which isn't available on this Mac right now."
    }

    public static func socialPlanSaved(weeks: Int, siteName: String) -> String {
        "Saved a \(weeks)-week social media plan for \(siteName) to docs/social-calendar.md."
    }

    public static func repurposeSummary(postTitle: String, platformCount: Int, failedCount: Int) -> String {
        var d = "Drafted \(platformCount) platform post\(platformCount == 1 ? "" : "s") for \"\(postTitle)\"."
        if failedCount > 0 { d += " \(failedCount) platform\(failedCount == 1 ? "" : "s") couldn't fit their length limit." }
        return d
    }
}

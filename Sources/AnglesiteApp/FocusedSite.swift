import SwiftUI

private struct FocusedSiteIDKey: FocusedValueKey { typealias Value = String }

extension FocusedValues {
    var siteID: String? {
        get { self[FocusedSiteIDKey.self] }
        set { self[FocusedSiteIDKey.self] = newValue }
    }
}

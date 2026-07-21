// AppKit-only half of `PreviewAnnotationProvider` (B.4 / #148): the
// `NSView.appEntityUIElementProvider` surface comes from the `_AppIntents_AppKit`
// cross-import overlay, so this file is macOS-only. The iOS thin client (#71) compiles the
// provider without it; a UIKit equivalent (`_AppIntents_UIKit`) is future work tracked on #71.
#if os(macOS)
import AppIntents
import AppKit
import CoreGraphics
import Foundation

// `AppEntityUIElement` and `AppEntityUIElementsContext` are defined by the
// `_AppIntents_AppKit` cross-import overlay, which auto-loads when both `AppIntents` and
// `AppKit` are imported explicitly in the consuming file. Swift's `MemberImportVisibility`
// upcoming-feature (enabled by the macOS 27 SDK module flags) requires both base modules
// here — transitive imports through other frameworks aren't enough, and the compile error
// blames the type rather than the missing import.

// `AppEntityUIElement` and `AppEntityUIElementsContext` are macOS 26+ symbols (Xcode 27 /
// Swift 6.4 SDK). CI's `macos-15` runner currently ships Xcode 26.3 / Swift 6.3 and doesn't
// have these types, so the methods that reference them are gated. Local Xcode 27 builds get
// the full surface; CI compiles the library without it. Same pattern as `Package.swift`'s
// `#if compiler(>=6.4)` gate around `AnglesiteIntentsTests`. Tracked for removal in #128
// when GH's runner ships Xcode 27.
#if compiler(>=6.4)
extension PreviewAnnotationProvider {
    /// Shape annotations into `[AppEntityUIElement]` for `NSView.appEntityUIElementProvider`
    /// (B.4 / #148). The system asks for either `.visible(rect:)` — return everything whose
    /// stored rect intersects `rect` — or `.selected`. We don't track an in-page selection
    /// model (the overlay's hover/click states are transient), so `.selected` yields `[]`.
    public func uiElements(for context: AppEntityUIElementsContext) -> [AppEntityUIElement] {
        uiElements(forRequests: context.requests)
    }

    /// Inner helper taking the raw request set so tests can drive it directly —
    /// `AppEntityUIElementsContext` has no public initializer.
    public func uiElements(
        forRequests requests: Set<AppEntityUIElementsContext.ElementsRequest>
    ) -> [AppEntityUIElement] {
        var out: [AppEntityUIElement] = []
        for request in requests {
            switch request {
            case .visible(let rect):
                for (annoRect, entity) in annotations() where annoRect.intersects(rect) {
                    out.append(makeUIElement(entity: entity, bounds: annoRect))
                }
            case .selected:
                continue
            @unknown default:
                continue
            }
        }
        return out
    }

    /// Existential-opening helper. `AppEntityUIElement.init<E: AppEntity>(_ entity:, bounds:)` is
    /// generic over a concrete entity type; each of the four concrete types we map to gets a
    /// dedicated branch so the compiler can specialize. The trailing fallback exists only to
    /// satisfy the type checker — the four cases above are exhaustive given `resolve`'s rules.
    /// If a fifth entity type is ever returned by `resolve` without updating this switch, the
    /// `assertionFailure` makes the regression loud in debug builds; release builds fall through
    /// to the placeholder so production keeps working.
    private func makeUIElement(entity: any AppEntity, bounds: CGRect) -> AppEntityUIElement {
        if let e = entity as? PageEntity { return AppEntityUIElement(e, bounds: bounds) }
        if let e = entity as? PostEntity { return AppEntityUIElement(e, bounds: bounds) }
        if let e = entity as? ImageEntity { return AppEntityUIElement(e, bounds: bounds) }
        if let e = entity as? ElementEntity { return AppEntityUIElement(e, bounds: bounds) }
        assertionFailure("makeUIElement: unhandled entity type \(type(of: entity)) — extend the switch in PreviewAnnotationProvider")
        let placeholder = ElementEntity(
            id: "unknown", displayName: "unknown", siteID: siteID,
            selector: "{}", pagePath: "/"
        )
        return AppEntityUIElement(placeholder, bounds: bounds)
    }
}
#endif
#endif

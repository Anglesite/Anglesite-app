import Foundation

/// The shared model-tier seam for content-help capabilities (#464/#465). Every heavy generation
/// path obtains its backend HERE with a requested `FoundationModelTier` — today `.privateCloudCompute`
/// is stubbed onto the on-device session inside `FoundationModelAssistant`; when real PCC (or
/// slice 5's escalation) lands, this factory is the one place that changes. `nil` below the
/// Xcode-27 toolchain (no FoundationModels — see #128), matching `SiteGraphExplainerFactory`.
public enum ContentAssistantFactory {
    public static func make(tier: FoundationModelTier) -> (any ContentAssistant)? {
        #if compiler(>=6.4) && canImport(FoundationModels)
        return FoundationModelAssistant(tier: tier)
        #else
        return nil
        #endif
    }
}

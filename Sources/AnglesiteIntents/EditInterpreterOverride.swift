import AnglesiteCore

/// Test seam: inject a fake `EditInterpreting` so `perform` doesn't touch the on-device model.
public enum EditInterpreterOverride {
    @TaskLocal public static var scoped: (any EditInterpreting)?
}

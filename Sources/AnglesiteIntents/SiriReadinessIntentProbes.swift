// Sources/AnglesiteIntents/SiriReadinessIntentProbes.swift
import AnglesiteCore
import AppIntents  // load-bearing: AnglesiteShortcuts.appShortcuts default-arg resolves [AppShortcut]

/// Confirms Anglesite's App Shortcuts are registered (the surface Siri/Spotlight enumerate).
/// Count is injectable; the default reads the live provider.
public struct AppIntentsRegistrationProbe: ReadinessProbe {
    public let id = "intents.registration"
    public let title = "App Intents & Shortcuts"
    /// `nil` means "read the live count at `check()` time". Resolving it lazily (rather than as a
    /// default argument) avoids reading the provider at struct-construction time, which can run
    /// before `AppDependencyManager` finishes wiring App Intents. `AnglesiteShortcuts.appShortcuts`
    /// is a static `@AppShortcutsBuilder` literal, so the live count is environment-independent.
    private let shortcutCount: Int?

    public init(shortcutCount: Int? = nil) {
        self.shortcutCount = shortcutCount
    }

    public func check() async -> ReadinessFinding {
        let shortcutCount = self.shortcutCount ?? AnglesiteShortcuts.appShortcuts.count
        if shortcutCount > 0 {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "\(shortcutCount) Anglesite shortcuts are registered for Siri and Spotlight.")
        }
        return ReadinessFinding(id: id, title: title, level: .warning,
            detail: "No Anglesite shortcuts are registered.",
            remediation: "Relaunch Anglesite so the system re-registers its App Shortcuts.")
    }
}

/// Reports whether the build includes Swift 6.4 View Annotations (the onscreen-awareness path
/// that lets Siri act on the site you're viewing). Compile-time gated; injectable for tests.
public struct ViewAnnotationsProbe: ReadinessProbe {
    public let id = "view.annotations"
    public let title = "Onscreen awareness (View Annotations)"
    private let compiled: Bool

    public init(compiled: Bool = ViewAnnotationsProbe.builtWithAnnotations) {
        self.compiled = compiled
    }

    public static var builtWithAnnotations: Bool {
        #if compiler(>=6.4)
        return true
        #else
        return false
        #endif
    }

    public func check() async -> ReadinessFinding {
        if compiled {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "Site windows publish an entity identifier, so Siri can act on the site you're viewing.")
        }
        return ReadinessFinding(id: id, title: title, level: .unsupported,
            detail: "This build was compiled without Swift 6.4 view-annotation support.",
            remediation: "Use a build produced with Xcode 27 / Swift 6.4 or later.")
    }
}

/// Reports whether Anglesite's tools are exposed to the system-wide MCP bridge. Unbuilt today
/// (Phase D, #135) — defaults to `.unsupported`; flips to a real check when #164/#101 land.
public struct SystemMCPBridgeProbe: ReadinessProbe {
    public let id = "mcp.bridge"
    public let title = "System-wide MCP bridge"
    private let registered: Bool

    // TODO(#135): replace the `false` default with a live system-MCP-bridge registration check
    // once Phase D lands (#164/#101). Until then this probe truthfully reports `.unsupported`.
    public init(registered: Bool = false) {
        self.registered = registered
    }

    public func check() async -> ReadinessFinding {
        if registered {
            return ReadinessFinding(id: id, title: title, level: .ok,
                detail: "Anglesite's tools are exposed to the system MCP bridge for external agents.")
        }
        return ReadinessFinding(id: id, title: title, level: .unsupported,
            detail: "System-wide MCP exposure is not available in this build (Phase D, #135).")
    }
}

import Foundation
import Virtualization

#if canImport(Containerization)
import Containerization
import ContainerizationOCI
#endif

// MARK: - Test harness

/// One JSON-line per probe so the run-matrix script can diff output across signings without
/// parsing prose. Each probe is independent — a tier-1 failure does not skip tier-2; we want
/// to see *every* sandbox/entitlement violation in one run.
struct ProbeResult: Codable {
    let tier: String
    let outcome: String   // "ok" | "denied" | "error"
    let detail: String?   // error message, framework class name, etc.
    let elapsedMs: Double
}

func emit(_ result: ProbeResult) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(result), let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

@inline(__always)
func timed<T>(_ body: () throws -> T) rethrows -> (T, Double) {
    let start = Date()
    let value = try body()
    let elapsedMs = Date().timeIntervalSince(start) * 1000
    return (value, elapsedMs)
}

@inline(__always)
func timedAsync<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let start = Date()
    let value = try await body()
    let elapsedMs = Date().timeIntervalSince(start) * 1000
    return (value, elapsedMs)
}

// MARK: - Tier 1: Virtualization.framework reachable

func probeTier1Virtualization() {
    let (config, elapsed) = timed { () -> VZVirtualMachineConfiguration in
        // Minimal VM config — no boot loader, no devices. Instantiation + validate() is enough to
        // exercise the framework's sandbox/entitlement gate without shipping a kernel image.
        let cfg = VZVirtualMachineConfiguration()
        cfg.cpuCount = 1
        cfg.memorySize = 128 * 1024 * 1024  // 128 MB — below VZ's minimum, so validate() should reject on config grounds
        return cfg
    }
    // `validate()` runs framework-side preflight against the same protected surface as actual VM
    // creation. Under a sandbox *without* com.apple.security.virtualization, we typically get an
    // NSXPCConnection / "operation not permitted" failure here. *With* the entitlement, validate()
    // rejects on configuration grounds (memory too small etc.) — that's success for our purposes.
    do {
        try config.validate()
        emit(ProbeResult(tier: "1-virtualization", outcome: "ok",
                         detail: "validate() unexpectedly accepted minimal config",
                         elapsedMs: elapsed))
    } catch let nsErr as NSError where nsErr.domain == "VZErrorDomain" {
        // The framework itself answered — but if the error message names the missing entitlement,
        // that's denial-by-entitlement, not denial-by-config. Observed verbatim on macOS 27 / unsigned:
        //   "Invalid virtual machine configuration. The process doesn't have the
        //    'com.apple.security.virtualization' entitlement."
        let msg = nsErr.localizedDescription
        let outcome = msg.lowercased().contains("entitlement") ? "denied" : "ok"
        let label = outcome == "denied" ? "VZErrorDomain entitlement denial" : "VZErrorDomain config rejection (framework reachable, entitlement present)"
        emit(ProbeResult(tier: "1-virtualization", outcome: outcome,
                         detail: "\(label): \(msg)",
                         elapsedMs: elapsed))
    } catch {
        let ns = error as NSError
        emit(ProbeResult(tier: "1-virtualization", outcome: "denied",
                         detail: "\(ns.domain) \(ns.code): \(ns.localizedDescription)",
                         elapsedMs: elapsed))
    }
}

// MARK: - Tier 2: vmnet networking reachable

func probeTier2Vmnet() {
    // VZNATNetworkDeviceAttachment doesn't require the vm.networking entitlement (NAT-only is fine).
    // VZBridgedNetworkDeviceAttachment *does* — that's what container-network-vmnet uses for the
    // routable per-container IP that the design doc relies on.
    let interfaces = VZBridgedNetworkInterface.networkInterfaces
    if interfaces.isEmpty {
        // No host bridge interfaces is system-dependent, not a sandbox signal — flag as inconclusive.
        emit(ProbeResult(tier: "2-vmnet-bridged", outcome: "error",
                         detail: "no bridged interfaces enumerated (system has no eligible NICs?)",
                         elapsedMs: 0))
        return
    }
    let (_, elapsed) = timed { () -> Void in
        // Just instantiating the attachment is enough — the entitlement gate fires when the
        // framework consults the bridged-networking surface. We'd normally hand this to a
        // VZVirtualMachineConfiguration; here we just need to see whether the framework
        // tolerates the call.
        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZBridgedNetworkDeviceAttachment(interface: interfaces[0])
        _ = nic.attachment
    }
    emit(ProbeResult(tier: "2-vmnet-bridged", outcome: "ok",
                     detail: "VZBridgedNetworkDeviceAttachment(\(interfaces[0].identifier)) instantiated — note: actual gate fires at VM start, not config-time",
                     elapsedMs: elapsed))
    // The real signal comes from tier 3 below: try to start a configured VM with a bridge
    // attachment, and observe whether the framework refuses at start because the bridge
    // requires com.apple.vm.networking. Logged from tier 3's error string.
}

// MARK: - Tier 3: Full Linux container boot via apple/containerization

func probeTier3Containerization() async {
    #if canImport(Containerization)
    // Placeholder for the actual container-boot test. The exact API surface from
    // apple/containerization isn't pinned in this scaffold — RunCommand.swift in cctl is the
    // reference. The shape is:
    //
    //   1. Pull or open a tiny OCI image (e.g. docker.io/library/alpine:3.20).
    //   2. Construct a LinuxContainer with a minimal process spec ("/bin/sh -c 'echo hello'").
    //   3. Start it, capture stdout, observe boot time.
    //
    // Whoever runs this spike: fill the body in by adapting from cctl's RunCommand.swift.
    // For the entitlement-detection purpose of this spike, tiers 1+2 already give the signal —
    // tier 3 is the *positive* confirmation under (A) DevID baseline.
    let (_, elapsed) = await timedAsync {
        // TODO: real boot. For now, mark as skipped with a clear note.
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    emit(ProbeResult(tier: "3-container-boot", outcome: "error",
                     detail: "scaffold-only — fill in LinuxContainer boot from apple/containerization cctl/RunCommand.swift",
                     elapsedMs: elapsed))
    #else
    emit(ProbeResult(tier: "3-container-boot", outcome: "error",
                     detail: "Containerization module not linked — `swift build` first",
                     elapsedMs: 0))
    #endif
}

// MARK: - Driver

@main struct ContainerSpike {
    static func main() async {
        // Banner — picked up by the run-matrix script to label which signing we're seeing.
        let bundleIdent = Bundle.main.bundleIdentifier ?? "<no bundle id>"
        FileHandle.standardError.write(Data("=== ContainerSpike start (pid \(getpid()), bundle \(bundleIdent)) ===\n".utf8))

        probeTier1Virtualization()
        probeTier2Vmnet()
        await probeTier3Containerization()

        FileHandle.standardError.write(Data("=== ContainerSpike done ===\n".utf8))
    }
}

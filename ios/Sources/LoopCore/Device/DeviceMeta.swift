import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Network)
import Network
#endif

/// Best-effort device metadata captured at submission time. Never throws,
/// never blocks, never collects PII. Each field has a benign default if the
/// platform can't supply it.
package struct DeviceMeta: Sendable {
    package let device: String
    package let os: String
    package let appVersion: String
    package let locale: String
    package let network: String
    package let sessionId: String

    package init(
        device: String,
        os: String,
        appVersion: String,
        locale: String,
        network: String,
        sessionId: String
    ) {
        self.device = device
        self.os = os
        self.appVersion = appVersion
        self.locale = locale
        self.network = network
        self.sessionId = sessionId
    }

    /// Snapshot the current environment. `sessionId` is generated once per
    /// SDK launch (see `LoopRuntime.sessionId`); this initializer accepts it
    /// rather than reading shared state, so the function stays pure.
    package static func capture(sessionId: String) -> DeviceMeta {
        DeviceMeta(
            device: deviceName(),
            os: osName(),
            appVersion: bundleVersion(),
            locale: localeIdentifier(),
            network: NetworkProbe.snapshot(),
            sessionId: sessionId
        )
    }

    // MARK: - Field helpers

    static func deviceName() -> String {
        #if os(iOS)
        // `UIDevice.current.model` returns "iPhone" / "iPad" — too coarse.
        // The real model identifier comes from `utsname.machine`, e.g.
        // "iPhone15,2" → we map known ones to friendly names, otherwise
        // fall back to the raw identifier.
        let raw = machineIdentifier()
        return Self.friendlyDeviceName(for: raw) ?? raw
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    /// The raw `utsname.machine` value, e.g. `"iPhone15,2"` (or the host
    /// architecture such as `"arm64"` on the simulator and macOS).
    static func machineIdentifier() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static func osName() -> String {
        #if os(iOS)
        return "iOS \(UIDevice.current.systemVersion)"
        #elseif os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        return "unknown"
        #endif
    }

    static func bundleVersion() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    static func localeIdentifier() -> String {
        let id = Locale.current.identifier
        return id.replacingOccurrences(of: "_", with: "-")
    }

    /// Tiny lookup for common iPhone identifiers. Out-of-table devices
    /// degrade to the raw `"iPhone15,2"` string, which is still useful in
    /// the dashboard. Update opportunistically.
    static func friendlyDeviceName(for raw: String) -> String? {
        switch raw {
        case "iPhone14,4": return "iPhone 13 mini"
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
        case "iPhone14,6": return "iPhone SE (3rd gen)"
        case "iPhone14,7": return "iPhone 14"
        case "iPhone14,8": return "iPhone 14 Plus"
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        case "iPhone15,4": return "iPhone 15"
        case "iPhone15,5": return "iPhone 15 Plus"
        case "iPhone16,1": return "iPhone 15 Pro"
        case "iPhone16,2": return "iPhone 15 Pro Max"
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "iPhone17,3": return "iPhone 16"
        case "iPhone17,4": return "iPhone 16 Plus"
        case "iPad13,18", "iPad13,19": return "iPad (10th gen)"
        case "iPad14,1", "iPad14,2": return "iPad mini (6th gen)"
        case "iPad14,3", "iPad14,4": return "iPad Pro 11\" (4th gen)"
        case "iPad14,5", "iPad14,6": return "iPad Pro 12.9\" (6th gen)"
        case "i386", "x86_64", "arm64":
            return "Simulator"
        default:
            return nil
        }
    }
}

/// Single-shot network type probe. Polls `NWPathMonitor` for a brief moment
/// and reports a coarse string ("WiFi", "Cellular", "Unknown"). Never
/// retains the monitor for live updates — capture is a one-off.
enum NetworkProbe {
    static func snapshot(timeout: TimeInterval = 0.25) -> String {
        #if canImport(Network)
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "io.loop.sdk.netprobe")

        var resolved: String?
        let semaphore = DispatchSemaphore(value: 0)

        monitor.pathUpdateHandler = { path in
            if resolved != nil { return }
            switch path.status {
            case .satisfied:
                if path.usesInterfaceType(.wifi) { resolved = "WiFi" }
                else if path.usesInterfaceType(.cellular) { resolved = "Cellular" }
                else if path.usesInterfaceType(.wiredEthernet) { resolved = "Ethernet" }
                else { resolved = "Online" }
            case .unsatisfied: resolved = "Offline"
            case .requiresConnection: resolved = "Requires-Connection"
            @unknown default: resolved = "Unknown"
            }
            semaphore.signal()
        }

        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()

        return resolved ?? "Unknown"
        #else
        return "Unknown"
        #endif
    }
}

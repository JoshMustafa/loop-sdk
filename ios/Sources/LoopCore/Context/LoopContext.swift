import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device and app facts sent as the batch-level `context` object. Captured
/// once; `locale` is the only field expected to change while the app runs.
package struct LoopContext: Equatable, Sendable {
    /// `iOS` or `macOS`.
    package var platform: String
    /// `ios` or `macos`.
    package var osName: String?
    package var osVersion: String?
    /// Version name only, e.g. `5.57.0`.
    package var appVersion: String?
    /// Build number, e.g. `1234`.
    package var appBuild: String?
    /// Raw model identifier, e.g. `iPhone17,1`.
    package var deviceModel: String?
    package var deviceManufacturer: String?
    package var deviceBrand: String?
    package var isTablet: Bool?
    /// BCP 47 style, e.g. `en-GB`.
    package var locale: String?

    package init(
        platform: String,
        osName: String? = nil,
        osVersion: String? = nil,
        appVersion: String? = nil,
        appBuild: String? = nil,
        deviceModel: String? = nil,
        deviceManufacturer: String? = nil,
        deviceBrand: String? = nil,
        isTablet: Bool? = nil,
        locale: String? = nil
    ) {
        self.platform = platform
        self.osName = osName
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.deviceModel = deviceModel
        self.deviceManufacturer = deviceManufacturer
        self.deviceBrand = deviceBrand
        self.isTablet = isTablet
        self.locale = locale
    }

    /// Snapshot of the running device and the app in `bundle`.
    package static func capture(bundle: Bundle = .main) -> LoopContext {
        let info = bundle.infoDictionary
        let appVersion = nonEmpty(info?["CFBundleShortVersionString"] as? String)
        let appBuild = nonEmpty(info?["CFBundleVersion"] as? String)
        let locale = localeTag(.current)

        #if os(iOS)
        let model = nonEmpty(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"])
            ?? nonEmpty(DeviceMeta.machineIdentifier())
        return LoopContext(
            platform: "iOS",
            osName: "ios",
            osVersion: nonEmpty(UIDevice.current.systemVersion),
            appVersion: appVersion,
            appBuild: appBuild,
            deviceModel: model,
            deviceManufacturer: "Apple",
            deviceBrand: nil,
            isTablet: model.map { $0.hasPrefix("iPad") },
            locale: locale
        )
        #else
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return LoopContext(
            platform: "macOS",
            osName: "macos",
            osVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            appVersion: appVersion,
            appBuild: appBuild,
            locale: locale
        )
        #endif
    }

    /// The wire `context` object. Nil fields are left out, except
    /// `purchaserId`, which is always present (`NSNull` when nil).
    package func json(purchaserId: String?, sdk: (name: String, version: String)) -> [String: Any] {
        var out: [String: Any] = ["platform": platform]
        out["osName"] = osName
        out["osVersion"] = osVersion
        out["appVersion"] = appVersion
        out["appBuild"] = appBuild
        out["deviceModel"] = deviceModel
        out["deviceManufacturer"] = deviceManufacturer
        out["deviceBrand"] = deviceBrand
        out["isTablet"] = isTablet
        out["locale"] = locale
        out["purchaserId"] = purchaserId ?? NSNull()
        out["sdk"] = ["name": sdk.name, "version": sdk.version]
        return out
    }

    /// A BCP 47 tag holding only language, optional script and optional
    /// region, e.g. `en-GB` or `zh-Hant-TW`. Keywords (`@calendar=…`,
    /// `-u-…`), variants and private-use parts are dropped.
    ///
    /// The script appears only when the locale's identifier names it.
    /// Foundation already drops a default script on creation
    /// (`Locale(identifier: "zh_Hant_TW").identifier == "zh_TW"`), so that
    /// locale gives `zh-TW`.
    static func localeTag(_ locale: Locale) -> String? {
        let base = locale.identifier.prefix { $0 != "@" }
        var subtags = base.split(whereSeparator: { $0 == "_" || $0 == "-" })[...]
        guard let language = subtags.popFirst(),
              (2...8).contains(language.count), language.allSatisfy(\.isLetter)
        else { return nil }

        var tag = [language.lowercased()]
        if let script = subtags.first, script.count == 4, script.allSatisfy(\.isLetter) {
            tag.append(script.prefix(1).uppercased() + script.dropFirst().lowercased())
            subtags = subtags.dropFirst()
        }
        if let region = subtags.first,
           (region.count == 2 && region.allSatisfy(\.isLetter))
            || (region.count == 3 && region.allSatisfy(\.isNumber)) {
            tag.append(region.uppercased())
        }
        return tag.joined(separator: "-")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

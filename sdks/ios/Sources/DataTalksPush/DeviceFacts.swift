import Foundation
import UserNotifications

/// What a registration reports about the device.
protocol DeviceFacts {
    func metadata() -> [String: String]

    /// Blocks. Call it off the main thread.
    func permission() -> String

    var environment: String { get }
}

/// This device's facts, cut to the contract's lengths: the ingress refuses a longer value, and a 4xx is never retried.
struct SystemFacts: DeviceFacts {
    func metadata() -> [String: String] {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let facts: [(String, String?, Int)] = [
            ("app_version", info?["CFBundleShortVersionString"] as? String, 64),
            ("app_build", info?["CFBundleVersion"] as? String, 64),
            ("os_version", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", 64),
            ("device_manufacturer", "Apple", 128),
            ("device_model", Self.modelIdentifier(), 128),
            ("locale", Locale.current.identifier.replacingOccurrences(of: "_", with: "-"), 35),
            ("time_zone", TimeZone.current.identifier, 64),
        ]

        var metadata: [String: String] = [:]
        for (name, value, maxLength) in facts {
            if let value, !value.isEmpty {
                metadata[name] = Self.cut(value, maxLength: maxLength)
            }
        }

        return metadata
    }

    func permission() -> String {
        let answered = DispatchSemaphore(value: 0)
        var status = UNAuthorizationStatus.notDetermined
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            status = settings.authorizationStatus
            answered.signal()
        }
        answered.wait()
        return Self.name(of: status)
    }

    var environment: String {
        #if targetEnvironment(simulator)
        return ApsEnvironment.sandbox
        #else
        return ApsEnvironment.current()
        #endif
    }

    static func name(of status: UNAuthorizationStatus) -> String {
        DataTalksPermission(status).rawValue
    }

    /// Cuts in UTF-16 units, as the ingress counts them, and never splits a character.
    static func cut(_ value: String, maxLength: Int) -> String {
        guard value.utf16.count > maxLength else { return value }

        var result = ""
        var length = 0
        for character in value {
            length += character.utf16.count
            if length > maxLength { break }
            result.append(character)
        }

        return result
    }

    private static func modelIdentifier() -> String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }

        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var machine = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &machine, &size, nil, 0) == 0 else { return nil }
        return String(cString: machine)
    }
}

extension DataTalksPermission {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .provisional: self = .provisional
        case .ephemeral: self = .ephemeral
        default: self = .notDetermined
        }
    }
}

/// The APNs environment of this build, from the provisioning profile embedded in the app.
enum ApsEnvironment {
    static let production = "production"
    static let sandbox = "sandbox"

    static func current(bundle: Bundle = .main) -> String {
        guard let path = bundle.path(forResource: "embedded", ofType: "mobileprovision"), let profile = FileManager.default.contents(atPath: path) else {
            // App Store builds have no profile.
            return production
        }

        return read(profile: profile)
    }

    /// A profile is a plist in a signed envelope. `aps-environment` is `development` in development builds; any other value, or none,
    /// means production.
    static func read(profile: Data) -> String {
        guard
            let start = profile.range(of: Data("<plist".utf8)),
            let end = profile.range(of: Data("</plist>".utf8), in: start.upperBound ..< profile.endIndex),
            let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound ..< end.upperBound], format: nil) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any]
        else {
            return production
        }

        return entitlements["aps-environment"] as? String == "development" ? sandbox : production
    }
}

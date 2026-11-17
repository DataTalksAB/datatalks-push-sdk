import Foundation
import os

enum AppKeys {
    private static let shape = try! NSRegularExpression(pattern: "^dtpk_(stg|prd)_(live|test)_[0-9A-Za-z]{32}$")

    /// The base URL of the key's environment, or nil for a malformed key.
    static func baseUrl(_ appKey: String) -> String? {
        let whole = NSRange(appKey.startIndex..., in: appKey)
        guard let match = shape.firstMatch(in: appKey, range: whole), let environment = Range(match.range(at: 1), in: appKey) else {
            return nil
        }

        return appKey[environment] == "prd" ? "https://push.datatalks.se/v1" : "https://push.staging.datatalks.se/v1"
    }
}

enum SdkInfo {
    static let version = "0.5.0-beta.1"
    static let header = "datatalks-push-ios/\(version)"
}

/// Never pass keys, secrets, tokens or identity values: messages are logged as public.
enum PushLog {
    private static let log = Logger(subsystem: "se.datatalks.push", category: "DataTalksPush")

    static func warning(_ message: String) {
        log.warning("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        log.error("\(message, privacy: .public)")
    }
}

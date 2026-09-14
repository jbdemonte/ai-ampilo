import Foundation
import os

public enum Redaction {
    public static func redact(_ value: String) -> String {
        var result = value
        for pattern in [#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, #"sk-[A-Za-z0-9_\-]+"#, #"eyJ[A-Za-z0-9_.\-]+"#, #"[A-Za-z0-9]{40,}"#] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: [.regularExpression, .caseInsensitive])
        }
        return result
    }
}
public enum Log {
    private static let logger = Logger(subsystem: "com.jbd.AIUsage", category: "refresh")
    public static func refresh(account: Account, error: ErrorKind? = nil, windows: Int = 0) {
        logger.info("provider=\(account.provider.rawValue, privacy: .public) account=\(account.id.uuidString, privacy: .public) result=\(error?.rawValue ?? "ok", privacy: .public) windows=\(windows)")
    }
}

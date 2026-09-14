import Foundation

public struct StatuslineSnapshot: Codable, Sendable {
    public var fetchedAt: Date
    public var windows: [UsageWindow]
    public static func capture(_ data: Data, now: Date = Date()) throws -> Self {
        struct Input: Decodable {
            struct Limits: Decodable {
                struct Window: Decodable { var used_percentage: Double?; var resets_at: Double? }
                var five_hour: Window?; var seven_day: Window?; var spend_limit: Window?
            }
            var rate_limits: Limits?
        }
        let input = try JSONDecoder().decode(Input.self, from: data)
        var windows: [UsageWindow] = []
        for (kind, value, duration) in [("session", input.rate_limits?.five_hour, 300), ("weekly_all", input.rate_limits?.seven_day, 10080)] {
            guard let value, let percent = value.used_percentage else { continue }
            windows.append(.init(id: "claude:\(kind)::", label: CodexRateLimitsMapper.windowLabel(duration), percent: percent, resetsAt: value.resets_at.map(Date.init(timeIntervalSince1970:)), durationMinutes: duration))
        }
        // Never persist the raw stdin: it contains workspace and session details unrelated to quotas.
        return .init(fetchedAt: now, windows: windows)
    }
    public func compactLine(now: Date = Date()) -> String {
        guard !windows.isEmpty else { return "Claude · " + L("Quota indisponible") }
        return "Claude · " + windows.map {
            $0.displayLabel() + " " + ($0.unconfirmedReset(at: now) ? "≈" : "") + String(Int($0.remainingPercent(at: now).rounded())) + "%"
        }.joined(separator: " | ") + " " + L("restants")
    }
    public func merging(into usage: AccountUsage) -> AccountUsage {
        guard fetchedAt > usage.fetchedAt else { return usage }
        var result = usage
        for window in windows {
            if let index = result.windows.firstIndex(where: { $0.id == window.id }) { result.windows[index] = window }
            else { result.windows.append(window) }
        }
        result.source = "claude-statusline"
        // Retained scoped windows still have the OAuth timestamp; do not claim they were refreshed by the hook.
        if result.windows.allSatisfy({ old in windows.contains { $0.id == old.id } }) { result.fetchedAt = fetchedAt }
        return result
    }
}
public struct StatuslineInstallation: Sendable {
    let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }
    public func outputURL(account: Account) -> URL { paths.file("statusline/" + digest(account.configPath, length: 8) + ".json") }
    private func backupURL(account: Account) -> URL { account.resolvedConfigDir.appendingPathComponent(".aiusage-statusline-backup.json") }
    public func install(account: Account, helper: URL) throws {
        let fm = FileManager.default
        let settingsURL = account.resolvedConfigDir.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) { settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] ?? [:] }
        let backup = backupURL(account: account)
        guard !fm.fileExists(atPath: backup.path) else { throw ErrorKind.invalidConfig }
        let old = settings["statusLine"]
        try fm.createDirectory(at: paths.file("statusline"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: paths.file("bin"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: account.resolvedConfigDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let localHelper = paths.file("bin/aiusage-cli")
        if fm.fileExists(atPath: localHelper.path) { try fm.removeItem(at: localHelper) }
        try fm.copyItem(at: helper, to: localHelper)
        // The helper has a SwiftPM resource bundle for localized quota labels.
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("AIUsage_AIUsageCore.bundle"), fm.fileExists(atPath: resources.path) {
            let destination = paths.file("bin/AIUsage_AIUsageCore.bundle")
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: resources, to: destination)
        }
        let previous = (old as? [String: Any])?["command"] as? String ?? ""
        let script = paths.file("bin/claude-statusline-" + digest(account.configPath, length: 8) + ".sh")
        let command = LoginCommand.quote(localHelper.path) + " --capture-statusline " + LoginCommand.quote(outputURL(account: account).path) + " " + LoginCommand.quote(previous)
        try Data(("#!/bin/sh\nexec " + command + "\n").utf8).write(to: script, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let installedCommand = LoginCommand.quote(script.path)
        let metadata: [String: Any] = ["previous": old ?? NSNull(), "installedCommand": installedCommand]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]).write(to: backup, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        var statusline = old as? [String: Any] ?? [:]
        statusline["type"] = "command"; statusline["command"] = installedCommand
        settings["statusLine"] = statusline
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
    }
    public func uninstall(account: Account) throws {
        let backup = backupURL(account: account), settingsURL = account.resolvedConfigDir.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: backup.path) else { return }
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any] ?? [:]
        var settings = try JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any] ?? [:]
        let current = (settings["statusLine"] as? [String: Any])?["command"] as? String
        // Preserve any statusline changes the user made after installation.
        if current == metadata["installedCommand"] as? String {
            settings["statusLine"] = metadata["previous"] is NSNull ? nil : metadata["previous"]
            try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]).write(to: settingsURL, options: .atomic)
        }
        try FileManager.default.removeItem(at: backup)
        try? FileManager.default.removeItem(at: outputURL(account: account))
    }
}

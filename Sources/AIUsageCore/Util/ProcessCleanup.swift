import Foundation

/// Tracks independent child cleanup workers so shutdown waits only for actual work.
public enum ProcessCleanup {
    private static let group = DispatchGroup()
    public static func schedule(_ work: @escaping @Sendable () -> Void) {
        group.enter()
        DispatchQueue.global().async { work(); group.leave() }
    }
    public static func wait() async {
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }
    }
}

public enum AppInstallation {
    public static func isInApplications(_ app: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let parent = app.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            .contains { parent.path == $0.resolvingSymlinksInPath().standardizedFileURL.path }
    }
}

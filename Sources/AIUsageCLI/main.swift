import Foundation
import AIUsageCore

@main struct UsageCLI {
    static func main() async {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "--capture-statusline" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let snapshot = data.count <= 4 * 1024 * 1024 ? try? StatuslineSnapshot.capture(data) : nil
            if let snapshot, !snapshot.windows.isEmpty {
                let encoder = JSONEncoder()
                try? encoder.encode(snapshot).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
            }
            if args.count >= 4, !args[3].isEmpty {
                do {
                    let session = try ProcessSession(executable: "/bin/sh", arguments: ["-c", args[3]], environment: ProcessInfo.processInfo.environment)
                    defer { session.close() }
                    let result = try await session.collect(timeout: 10, input: data)
                    try FileHandle.standardOutput.write(contentsOf: result.stdout)
                } catch {}
            } else {
                print(snapshot?.compactLine() ?? "Claude · " + L("Quota indisponible"))
            }
            await ProcessCleanup.wait()
            return
        }
        let engine = UsageEngine()
        for provider in Provider.allCases.filter(\.automaticallyAdded) {
            let account = Account(provider: provider)
            let outcome = await engine.refresh(account: account, settings: Settings(), reason: .manual)
            switch outcome {
            case .success(let usage):
                print(provider.title)
                for window in usage.windows { print("  \(window.displayLabel()): \(Int(window.remainingPercent(at: Date()).rounded())) % " + L("restants")) }
            case .failure(let error): print("\(provider.title): \(error.kind.message)")
            case .missing: print("\(provider.title): \(L("CLI introuvable"))")
            case .skipped: break
            }
        }
        await engine.stop(); await ProcessCleanup.wait()
    }
}

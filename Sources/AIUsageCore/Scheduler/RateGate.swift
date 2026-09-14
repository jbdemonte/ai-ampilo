import Foundation

public enum RefreshReason: Sendable { case scheduled, manual, popover, wake, network, account, renewed }
public actor RateGate {
    private var lastStart: Date?
    private var hardUntil = Date.distantPast
    private var softUntil = Date.distantPast
    private var failures = 0
    private var busy = false
    private var retryCredit = false
    private let minimum: TimeInterval
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    public init(provider: Provider, now: @escaping @Sendable () -> Date = Date.init, jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        minimum = provider.minimumInterval; self.now = now; self.jitter = jitter
    }
    public func authorizeRenewedRetry() { retryCredit = true }
    public func begin(_ reason: RefreshReason) -> Bool {
        let date = now()
        guard !busy, date >= hardUntil else { return false }
        let exception = reason == .renewed && retryCredit
        guard exception || lastStart.map({ date.timeIntervalSince($0) >= minimum }) ?? true else { return false }
        guard reason == .manual || exception || date >= softUntil else { return false }
        busy = true; lastStart = date; retryCredit = false
        return true
    }
    public func finish(error: ProviderFailure? = nil, interval: TimeInterval) {
        busy = false
        guard let error else { failures = 0; softUntil = .distantPast; return }
        switch error.kind {
        case .rateLimited: hardUntil = now().addingTimeInterval(max(600, error.retryAfter ?? 600) * (1 + jitter() * 0.1))
        case .policy: hardUntil = now().addingTimeInterval(21600)
        case .network, .server, .timeout, .process, .accessDenied:
            failures += 1
            softUntil = now().addingTimeInterval(Backoff.delay(interval: interval, failures: failures, jitter: jitter()))
        default: break
        }
    }
    public func remaining() -> TimeInterval {
        max(0, max(hardUntil, lastStart?.addingTimeInterval(minimum) ?? .distantPast).timeIntervalSince(now()))
    }
}
public enum Backoff {
    public static func delay(interval: TimeInterval, failures: Int, jitter: Double) -> TimeInterval {
        min(max(60, interval) * pow(2, Double(min(10, max(0, failures)))), 3600) * (0.9 + 0.2 * jitter)
    }
}
public actor RefreshScheduler {
    private var task: Task<Void, Never>?
    public init() {}
    public func start(interval: TimeInterval, action: @escaping @Sendable () async -> Void) {
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(max(60, interval))) } catch { break }
                await action()
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }
}

import Foundation

/// Serial, cancellable status checks. The owner pauses this during host controls
/// and streaming; an operation must check cancellation before publishing results.
@MainActor public final class IdleHostPoller {
    private let interval: Duration
    private var task: Task<Void, Never>?

    public init(interval: Duration = .seconds(5)) { self.interval = interval }

    public func start(immediately: Bool = false, operation: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        let interval = interval
        task = Task {
            if immediately, !Task.isCancelled { await operation() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

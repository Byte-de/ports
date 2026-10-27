/// Serialises refreshes. A request made while one runs schedules exactly one trailing run instead of being dropped,
/// and resumes after that run, so await always covers a scan that started after the call.
@MainActor
public final class RefreshCoalescer {
    public private(set) var isRunning = false
    private var pending = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let operation: @MainActor () async -> Void

    public init(_ operation: @escaping @MainActor () async -> Void) {
        self.operation = operation
    }

    public func request() async {
        if isRunning {
            pending = true
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            // Waiters taken before the run starts are the ones this run covers.
            pending = false
            let covered = waiters
            waiters = []
            await operation()
            for waiter in covered { waiter.resume() }
        } while pending
    }
}

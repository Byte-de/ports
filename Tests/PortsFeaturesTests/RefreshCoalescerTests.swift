import PortsFeatures
import Testing

@MainActor
struct RefreshCoalescerTests {
    @Test func requestsDuringARunShareOneTrailingRun() async {
        let gate = Gate()
        let coalescer = RefreshCoalescer { await gate.run() }
        let callers = Callers(coalescer, gate)
        let first = callers.start()
        #expect(await eventually { gate.started == 1 })
        #expect(coalescer.isRunning)
        let queued = [callers.start(), callers.start(), callers.start()]
        #expect(await eventually { callers.entered == 4 })
        gate.release()
        #expect(await eventually { gate.started == 2 })
        #expect(callers.returnedAfter.isEmpty)
        gate.release()
        await first.value
        for caller in queued { await caller.value }
        #expect(gate.started == 2)
        #expect(callers.returnedAfter == [2, 2, 2, 2])
        #expect(!coalescer.isRunning)
    }

    @Test func requestDuringTheTrailingRunGetsAThirdRun() async {
        let gate = Gate()
        let coalescer = RefreshCoalescer { await gate.run() }
        let callers = Callers(coalescer, gate)
        let first = callers.start()
        #expect(await eventually { gate.started == 1 })
        let second = callers.start()
        #expect(await eventually { callers.entered == 2 })
        gate.release()
        #expect(await eventually { gate.started == 2 })
        let third = callers.start()
        #expect(await eventually { callers.entered == 3 })
        gate.release()
        #expect(await eventually { gate.started == 3 })
        await second.value
        gate.release()
        await first.value
        await third.value
        #expect(gate.started == 3)
        #expect(callers.returnedAfter == [2, 3, 3])
        #expect(!coalescer.isRunning)
    }

    @Test func sequentialRequestsEachRun() async {
        let gate = Gate(holdsRuns: false)
        let coalescer = RefreshCoalescer { await gate.run() }
        for _ in 0..<3 { await coalescer.request() }
        #expect(gate.started == 3)
        #expect(gate.finished == 3)
        #expect(!coalescer.isRunning)
    }
}

/// Holds each run open until the test releases it, so requests can arrive while a run is in progress.
@MainActor
private final class Gate {
    private(set) var started = 0
    private(set) var finished = 0
    private let holdsRuns: Bool
    private var held: CheckedContinuation<Void, Never>?

    init(holdsRuns: Bool = true) { self.holdsRuns = holdsRuns }

    func run() async {
        started += 1
        if holdsRuns { await withCheckedContinuation { held = $0 } }
        finished += 1
    }

    func release() {
        held?.resume()
        held = nil
    }
}

/// Records how many runs had finished when each caller's request returned.
@MainActor
private final class Callers {
    private(set) var entered = 0
    private(set) var returnedAfter: [Int] = []
    private let coalescer: RefreshCoalescer
    private let gate: Gate

    init(_ coalescer: RefreshCoalescer, _ gate: Gate) {
        self.coalescer = coalescer
        self.gate = gate
    }

    func start() -> Task<Void, Never> {
        Task {
            entered += 1
            await coalescer.request()
            returnedAfter.append(gate.finished)
        }
    }
}

/// Yields to queued main-actor work until the condition holds.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<1_000 where !condition() { await Task.yield() }
    return condition()
}

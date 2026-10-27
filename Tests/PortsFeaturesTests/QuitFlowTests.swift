import Foundation
import PortsFeatures
import Testing

struct QuitFlowTests {
    private let api = QuitFlow.Job(id: UUID(), name: "API")
    private let web = QuitFlow.Job(id: UUID(), name: "Web")
    private let docs = QuitFlow.Job(id: UUID(), name: "Docs")

    private func userFlow() -> QuitFlow { QuitFlow(jobs: [api, web, docs], isSessionEnd: false) }

    /// A user flow whose first stop left `remaining` alive.
    private func unresponsiveFlow(_ remaining: Set<UUID>) -> QuitFlow {
        var flow = userFlow()
        _ = flow.confirm()
        _ = flow.stopFinished(remaining: remaining)
        return flow
    }

    @Test func userQuitNeverForcesWithoutExplicitAction() {
        var flow = userFlow()
        #expect(flow.phase == .confirming)
        #expect(flow.confirm() == .stopAll(grace: .seconds(15)))
        #expect(flow.phase == .stopping)
        #expect(flow.stopFinished(remaining: [web.id]) == .none)
        #expect(flow.phase == .unresponsive)
        #expect(flow.remainingJobs == [web])
        // Waiting again and again still never escalates on its own.
        for _ in 0..<3 {
            #expect(flow.keepWaiting() == .wait(grace: .seconds(15)))
            #expect(flow.stopFinished(remaining: [web.id]) == .none)
            #expect(flow.phase == .unresponsive)
        }
        #expect(flow.forceQuit() == .forceStop([web.id]))
        #expect(flow.phase == .forcing)
    }

    @Test func forceTargetsOnlyRemainingJobs() {
        var flow = unresponsiveFlow([web.id, docs.id])
        #expect(flow.forceQuit() == .forceStop([web.id, docs.id]))
        #expect(flow.forceFinished(remaining: []) == .terminate)
        #expect(flow.phase == .finished)
    }

    @Test func sessionEndSkipsConfirmationNeverForcesAndAlwaysTerminates() {
        var flow = QuitFlow(jobs: [api, web], isSessionEnd: true)
        #expect(flow.phase == .stopping)
        #expect(flow.confirm() == .none)
        #expect(flow.begin() == .stopAll(grace: .seconds(5)))
        #expect(flow.cancel() == .none)
        #expect(flow.forceQuit() == .none)
        #expect(flow.stopFinished(remaining: [web.id]) == .terminate)
        #expect(flow.phase == .finished)
        #expect(flow.forceQuit() == .none)
        #expect(flow.cancel() == .none)
    }

    @Test func noJobsSkipsConfirmation() {
        var flow = QuitFlow(jobs: [], isSessionEnd: false)
        #expect(flow.phase == .stopping)
        #expect(flow.begin() == .stopAll(grace: .seconds(15)))
        #expect(flow.begin() == .none)
        #expect(flow.stopFinished(remaining: []) == .terminate)
    }

    @Test func cancelFromStoppingResumesAndIgnoresLateResults() {
        var flow = userFlow()
        _ = flow.confirm()
        #expect(flow.cancel() == .resume)
        #expect(flow.phase == .cancelled)
        #expect(!flow.isActive)
        #expect(flow.stopFinished(remaining: []) == .none)
        #expect(flow.forceFinished(remaining: []) == .none)
        #expect(flow.phase == .cancelled)
        #expect(flow.cancel() == .none)
    }

    @Test(arguments: [QuitFlow.Phase.confirming, .unresponsive, .forcing, .failed])
    func everyUserPhaseCanBeCancelled(phase: QuitFlow.Phase) {
        var flow = unresponsiveFlow([web.id])
        switch phase {
        case .confirming: flow = userFlow()
        case .forcing: _ = flow.forceQuit()
        case .failed:
            _ = flow.forceQuit()
            _ = flow.forceFinished(remaining: [web.id])
        default: break
        }
        #expect(flow.phase == phase)
        #expect(flow.cancel() == .resume)
        #expect(flow.phase == .cancelled)
    }

    @Test func keepWaitingWaitsWithoutResignal() {
        var flow = unresponsiveFlow([api.id])
        let effect = flow.keepWaiting()
        #expect(effect == .wait(grace: .seconds(15)))
        #expect(effect != .stopAll(grace: .seconds(15)))
        #expect(flow.phase == .stopping)
        #expect(flow.stopFinished(remaining: []) == .terminate)
    }

    @Test func failedOffersQuitAnyway() {
        var flow = unresponsiveFlow([api.id, web.id])
        _ = flow.forceQuit()
        #expect(flow.forceFinished(remaining: [web.id]) == .none)
        #expect(flow.phase == .failed)
        #expect(flow.remainingJobs == [web])
        #expect(flow.forceQuit() == .none)
        #expect(flow.keepWaiting() == .none)
        #expect(flow.quitAnyway() == .terminate)
        #expect(flow.phase == .finished)
    }

    @Test func invalidTransitionsAreNoOps() {
        var confirming = userFlow()
        let before = confirming
        #expect(confirming.begin() == .none)
        #expect(confirming.stopFinished(remaining: []) == .none)
        #expect(confirming.keepWaiting() == .none)
        #expect(confirming.forceQuit() == .none)
        #expect(confirming.forceFinished(remaining: []) == .none)
        #expect(confirming.quitAnyway() == .none)
        #expect(confirming == before)

        var stopping = userFlow()
        _ = stopping.confirm()
        let started = stopping
        #expect(stopping.confirm() == .none)
        #expect(stopping.begin() == .none)
        #expect(stopping.keepWaiting() == .none)
        #expect(stopping.forceQuit() == .none)
        #expect(stopping.quitAnyway() == .none)
        #expect(stopping == started)

        var unresponsive = unresponsiveFlow([api.id])
        let waiting = unresponsive
        #expect(unresponsive.stopFinished(remaining: []) == .none)
        #expect(unresponsive.forceFinished(remaining: []) == .none)
        #expect(unresponsive.quitAnyway() == .none)
        #expect(unresponsive == waiting)

        // An unstarted flow without confirmation ignores results until it begins.
        var silent = QuitFlow(jobs: [], isSessionEnd: true)
        #expect(silent.stopFinished(remaining: []) == .none)
        #expect(silent.phase == .stopping)
    }

    @Test func sessionEndsByQuitReasonOrRecentPowerOffNotice() {
        for reason in [kAEReallyLogOut, kAERestart, kAEShutDown, kAEQuitAll] {
            #expect(SessionEnd.isSessionEnd(quitReason: reason, powerOffNoticeAge: nil))
        }
        #expect(!SessionEnd.isSessionEnd(quitReason: nil, powerOffNoticeAge: nil))
        #expect(!SessionEnd.isSessionEnd(quitReason: kAEQuitApplication, powerOffNoticeAge: nil))
        #expect(SessionEnd.isSessionEnd(quitReason: nil, powerOffNoticeAge: .seconds(2)))
        #expect(SessionEnd.isSessionEnd(quitReason: nil, powerOffNoticeAge: .seconds(30)))
        #expect(!SessionEnd.isSessionEnd(quitReason: nil, powerOffNoticeAge: .seconds(31)))
        #expect(!SessionEnd.isSessionEnd(quitReason: kAEQuitApplication, powerOffNoticeAge: .seconds(120)))
    }
}

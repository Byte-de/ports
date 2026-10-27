import Foundation
import PortsFeatures
import Testing

@testable import PortsCore

struct LaunchListingTests {
    private let api = LaunchConfiguration(name: "API", command: "npm run api", directory: "/tmp")
    private let web = LaunchConfiguration(name: "Web", command: "npm run dev", directory: "/tmp")
    private let docs = LaunchConfiguration(name: "Docs", command: "npm run docs", directory: "/tmp")

    private func job(
        _ configuration: LaunchConfiguration, createdAt: TimeInterval = 0, run: UUID = UUID(),
        _ state: LaunchState = .running, exit: Int32? = nil
    ) -> LaunchRecord {
        LaunchRecord(
            id: configuration.id, runID: run, configuration: configuration, identity: nil,
            createdAt: Date(timeIntervalSince1970: createdAt), startedAt: Date(timeIntervalSince1970: createdAt),
            runCount: 1, state: state, exitCode: exit)
    }

    @Test func savedOrderIsPreserved() {
        let rows = LaunchListing.rows(
            saved: [web, api, docs], jobs: [job(api, createdAt: 3), job(docs, createdAt: 1), job(web, createdAt: 2)])
        #expect(rows.saved.map(\.id) == [web.id, api.id, docs.id])
        #expect(rows.saved.allSatisfy { $0.isSaved && $0.job?.id == $0.id })
        #expect(rows.oneOff.isEmpty)
    }

    @Test func savedActionThatNeverRanHasNoJob() {
        let rows = LaunchListing.rows(saved: [api], jobs: [])
        #expect(rows.saved.map(\.id) == [api.id])
        #expect(rows.saved.first?.job == nil)
    }

    @Test func jobOfDeletedSavedActionMovesToOneOff() {
        let rows = LaunchListing.rows(saved: [web], jobs: [job(api), job(web)])
        #expect(rows.saved.map(\.id) == [web.id])
        #expect(rows.oneOff.map(\.id) == [api.id])
        #expect(rows.oneOff.first?.isSaved == false)
        #expect(rows.oneOff.first?.configuration == api)
    }

    @Test func oneOffNewestFirst() {
        let rows = LaunchListing.rows(
            saved: [], jobs: [job(web, createdAt: 2), job(api, createdAt: 1), job(docs, createdAt: 3)])
        #expect(rows.oneOff.map(\.id) == [docs.id, web.id, api.id])
    }

    @Test func savedRowUsesCurrentNameNotSnapshot() {
        var renamed = api
        renamed.name = "API v2"
        let rows = LaunchListing.rows(saved: [renamed], jobs: [job(api)])
        #expect(rows.saved.first?.configuration.name == "API v2")
        #expect(rows.saved.first?.job?.configuration.name == "API")
    }

    @Test func transitionsReportRunsThatEndedOnTheirOwn() {
        let finished = job(api, .finished, exit: 0)
        let failed = job(web, .failed, exit: 1)
        let events = LaunchListing.transitions(
            old: [job(api, run: finished.runID), job(web, run: failed.runID)], new: [finished, failed],
            userInitiated: [])
        #expect(events == [.exited(finished), .failed(failed, userInitiated: false)])
    }

    @Test func transitionsIgnoreStopsUnchangedEndsAndLiveRuns() {
        let stopped = job(api, .stopped, exit: 15)
        let failed = job(web, .failed, exit: 1)
        let unresponsive = job(docs, .unresponsive)
        let events = LaunchListing.transitions(
            old: [job(api, run: stopped.runID), failed, job(docs, run: unresponsive.runID)],
            new: [stopped, failed, unresponsive], userInitiated: [])
        #expect(events.isEmpty)
    }

    @Test func runThatStartedAndEndedBetweenReadsIsReported() {
        let first = job(api, .failed, exit: 1)
        let quick = job(web, .failed, exit: 127)
        let again = job(api, .failed, exit: 2)
        #expect(
            LaunchListing.transitions(old: [], new: [quick], userInitiated: [])
                == [.failed(quick, userInitiated: false)])
        // The same slot ran again and failed again before the next read.
        #expect(
            LaunchListing.transitions(old: [first], new: [again], userInitiated: [])
                == [.failed(again, userInitiated: false)])
    }

    @Test func failureDuringUserActionIsMarked() {
        let failed = job(api, .failed, exit: 1)
        let events = LaunchListing.transitions(
            old: [job(api, run: failed.runID)], new: [failed], userInitiated: [api.id])
        #expect(events == [.failed(failed, userInitiated: true)])
    }

    @Test func removedSlotsReportNothing() {
        #expect(LaunchListing.transitions(old: [job(api), job(web, .finished)], new: [], userInitiated: []).isEmpty)
    }

    @Test func runIsLiveOnlyWhileItIsTheSlotsActiveRun() {
        let running = job(api)
        #expect(LaunchListing.isLive(running, in: [job(web), job(api, run: running.runID, .unresponsive)]))
        #expect(!LaunchListing.isLive(running, in: [job(api, run: running.runID, .stopped, exit: 15)]))
        #expect(!LaunchListing.isLive(running, in: [job(api, run: running.runID, .failed, exit: 1)]))
        // Replaced by a new run, or the slot was removed.
        #expect(!LaunchListing.isLive(running, in: [job(api)]))
        #expect(!LaunchListing.isLive(running, in: [job(web)]))
    }
}

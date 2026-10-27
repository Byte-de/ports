import Foundation
import PortsCore

/// A row of the Actions tab: a saved action with its slot, once it ran, or a slot whose configuration is not saved.
public struct LaunchRow: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// A saved action's current configuration, so a rename shows at once; otherwise the one the slot ran last.
    public let configuration: LaunchConfiguration
    public let job: LaunchRecord?
    public let isSaved: Bool
}

/// How a run ended on its own, found by comparing two reads of the slots. Stops are reported by the stop itself.
public enum LaunchEvent: Equatable, Sendable {
    /// Exited with status 0.
    case exited(LaunchRecord)
    /// Exited with another status or a signal. `userInitiated` when it ended while the user acted on the slot, whose
    /// action then reports the outcome.
    case failed(LaunchRecord, userInitiated: Bool)
}

public enum LaunchListing {
    /// Saved rows keep the saved order; the other slots follow newest first, including those of deleted actions.
    public static func rows(
        saved: [LaunchConfiguration], jobs: [LaunchRecord]
    ) -> (saved: [LaunchRow], oneOff: [LaunchRow]) {
        let jobs = Dictionary(jobs.map { ($0.id, $0) }) { first, _ in first }
        let savedIDs = Set(saved.map(\.id))
        let savedRows = saved.map { LaunchRow(id: $0.id, configuration: $0, job: jobs[$0.id], isSaved: true) }
        let oneOff = jobs.values.filter { !savedIDs.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
            .map { LaunchRow(id: $0.id, configuration: $0.configuration, job: $0, isSaved: false) }
        return (savedRows, oneOff)
    }

    /// Runs that ended between two reads. A run counts when it was alive in `old`, or started and ended in between,
    /// so a command that fails at once is still reported. `userInitiated` holds the slots the user is acting on.
    public static func transitions(
        old: [LaunchRecord], new: [LaunchRecord], userInitiated: Set<UUID>
    ) -> [LaunchEvent] {
        let previous = Dictionary(old.map { ($0.id, $0) }) { first, _ in first }
        var events: [LaunchEvent] = []
        for record in new where !record.state.isActive {
            if let before = previous[record.id], before.runID == record.runID, !before.state.isActive { continue }
            switch record.state {
            case .finished: events.append(.exited(record))
            case .failed: events.append(.failed(record, userInitiated: userInitiated.contains(record.id)))
            case .running, .stopping, .unresponsive, .stopped: continue
            }
        }
        return events
    }

    /// Whether `job`'s run is still the slot's run and alive in `records`. A stop confirmation for a run that ended or
    /// was replaced would report a stop that never happened.
    public static func isLive(_ job: LaunchRecord, in records: [LaunchRecord]) -> Bool {
        records.contains { $0.id == job.id && $0.runID == job.runID && $0.state.isActive }
    }
}

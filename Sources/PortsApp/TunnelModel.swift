import Accessibility
import AppKit
import Foundation
import PortsCore
import PortsFeatures
import SwiftUI

extension MonitorModel {
    /// nil when the server can't be shared, including a port that already answered something other than HTTP.
    func tunnelTarget(_ service: ServiceRecord, endpoint: ListeningEndpoint? = nil) -> TunnelTarget? {
        guard let endpoint = endpoint ?? service.primaryEndpoint,
            let target = try? TunnelTarget(service: service, endpoint: endpoint),
            !nonHTTPTargets.contains(target.id)
        else { return nil }
        return target
    }

    func tunnelRecord(_ target: TunnelTarget) -> TunnelRecord? {
        tunnelRecords.first { $0.id == target.id }
    }

    /// The port's one share, whichever of its addresses started it.
    func tunnelRecord(for process: ProcessIdentity, port: UInt16) -> TunnelRecord? {
        guard !demoMode else { return nil }
        return tunnelRecords.first { $0.id.process == process && $0.id.port == port }
    }

    /// A database or cache daemon, or a port whose share check got something other than HTTP back.
    func answersNoHTTP(_ service: ServiceRecord, port: UInt16) -> Bool {
        service.kind == .server
            && (service.isKnownNonHTTP || nonHTTPTargets.contains { $0.process == service.id && $0.port == port })
    }

    var activeShares: [TunnelRecord] { PublicSharing.activeShares(records: tunnelRecords, demoMode: demoMode) }

    /// Drives the globe in the menu bar and the notch.
    var isSharingPublicly: Bool { !activeShares.isEmpty }

    func visibleTunnels(for service: ServiceRecord) -> [TunnelRecord] {
        guard !demoMode else { return [] }
        return tunnelRecords.filter { $0.id.process == service.id && $0.phase != .stopped }
            .sorted { $0.target.endpoint.port < $1.target.endpoint.port }
    }

    func share(_ target: TunnelTarget, from surface: MonitorSurface) {
        guard !demoMode, !isQuitting, !isSwitchingDemo, !hasPanelDialog else { return }
        if let record = tunnelRecord(target), record.phase.isActive {
            if record.phase == .ready, let url = record.publicURL {
                copy(url.absoluteString, message: "Share link copied")
            }
            return
        }
        guard preferences.hasAcknowledgedPublicSharing else {
            presentationSurface = PanelWindowCoordinator.shared.dialogSurface(from: surface)
            dialogUsesMotion = PanelMotion.isPointerEvent
            pendingShare = target
            return
        }
        guard sharingBusy.insert(target.id).inserted else { return }
        presentationSurface = surface
        // Counts from the click that starts the share, which comes after consent.
        pendingShareCopies[target.id] = ShareLinkHandoff(
            pasteboardChangeCount: NSPasteboard.general.changeCount, clickedAt: .now)
        Task {
            defer { sharingBusy.remove(target.id) }
            guard !demoMode, !isQuitting, !isSwitchingDemo else {
                pendingShareCopies[target.id] = nil
                return
            }
            do {
                try await tunnels.start(target)
                await updateTunnels()
            } catch {
                pendingShareCopies[target.id] = nil
                // A stop-all during the probe cancelled the start on purpose.
                if error is CancellationError { return }
                // The share action disappears for this port until its process exits.
                if case TunnelError.notHTTP = error { nonHTTPTargets.insert(target.id) }
                report(error, as: .share)
            }
        }
    }

    func stopSharing(_ record: TunnelRecord) {
        pendingShareCopies[record.id] = nil
        Task {
            do {
                if record.phase.isActive { try await tunnels.stop(record.id) } else { await tunnels.dismiss(record.id) }
                await updateTunnels()
            } catch { report(error, as: .stopSharing) }
        }
    }

    /// Applies every snapshot the manager publishes, so nothing wakes up while no share runs. Called once: the
    /// stream outlives a cancelled quit.
    func observeTunnels() {
        guard tunnelObserver == nil else { return }
        let tunnels = tunnels
        tunnelObserver = Task { [weak self] in
            for await records in await tunnels.updates() {
                guard let self else { return }
                self.applyTunnelRecords(records)
            }
        }
    }

    /// Reads the records directly, so an action's own result is applied before its caller continues.
    func updateTunnels() async { applyTunnelRecords(await tunnels.records()) }

    /// Idempotent: the stream and `updateTunnels()` can deliver the same snapshot.
    private func applyTunnelRecords(_ latest: [TunnelRecord]) {
        if latest != tunnelRecords {
            withAnimation(PanelMotion.reduceMotion ? nil : PanelMotion.settle(0.20)) {
                tunnelRecords = latest
            }
        }
        guard !pendingShareCopies.isEmpty else { return }
        for record in tunnelRecords {
            guard let handoff = pendingShareCopies[record.id] else { continue }
            // Until its start returns, an ended record is the port's previous share.
            if sharingBusy.contains(record.id) && !record.phase.isActive { continue }
            // Read per record: copying one share's link changes the pasteboard for the next.
            let decision = handoff.decide(
                phase: record.phase, hasURL: record.publicURL != nil,
                pasteboardChangeCount: NSPasteboard.general.changeCount, now: .now)
            guard decision != .wait else { continue }
            pendingShareCopies[record.id] = nil
            // A quit or a switch to the demo ends the share anyway.
            guard !isQuitting && !isSwitchingDemo else { continue }
            let message: LocalizedStringResource
            switch decision {
            case .copy:
                guard let url = record.publicURL else { continue }
                message = "Share link copied"
                copy(url.absoluteString, message: message, animateFeedback: true)
            case .offer:
                message = "Share is live · copy the link from its row"
                notify(message)
            case .wait, .discard: continue
            }
            // The link may arrive while VoiceOver is elsewhere, and the toast alone is silent.
            AccessibilityNotification.Announcement(String(localized: message)).post()
        }
        // A start that failed before its first record leaves its handoff behind.
        let live = Set(tunnelRecords.map(\.id)).union(sharingBusy)
        pendingShareCopies = pendingShareCopies.filter { live.contains($0.key) }
    }
}

extension TunnelPhase {
    /// One share's state as its row names it.
    var statusTitle: LocalizedStringResource {
        switch self {
        case .starting: "Connecting to Cloudflare…"
        case .ready: "Public · Cloudflare"
        case .reconnecting: "Reconnecting…"
        case .stopping: "Stopping share…"
        case .stopped, .failed: "Share ended"
        }
    }
}

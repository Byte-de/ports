import AppKit
import Foundation
import PortsCore
import SwiftUI

extension MonitorModel {
    func tunnelTarget(_ service: ServiceRecord, endpoint: ListeningEndpoint? = nil) -> TunnelTarget? {
        guard let endpoint = endpoint ?? service.primaryEndpoint else { return nil }
        return try? TunnelTarget(service: service, endpoint: endpoint)
    }

    func tunnelRecord(_ target: TunnelTarget) -> TunnelRecord? {
        tunnelRecords.first { $0.id == target.id }
    }

    func visibleTunnels(for service: ServiceRecord) -> [TunnelRecord] {
        guard !demoMode else { return [] }
        return tunnelRecords.filter { $0.id.process == service.id && $0.phase != .stopped }
            .sorted { $0.target.endpoint.port < $1.target.endpoint.port }
    }

    func share(_ target: TunnelTarget, from surface: MonitorSurface) {
        guard !demoMode, !isQuitting, !isSwitchingDemo, !hasPanelDialog else { return }
        if let record = tunnelRecord(target), record.phase.isActive {
            if record.phase == .ready, let url = record.publicURL {
                copy(url.absoluteString, message: "Freigabelink kopiert")
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
        pendingTunnelCopy.insert(target.id)
        Task {
            defer { sharingBusy.remove(target.id) }
            guard !demoMode, !isQuitting, !isSwitchingDemo else {
                pendingTunnelCopy.remove(target.id)
                return
            }
            do {
                try await tunnels.start(target)
                await updateTunnels()
            } catch {
                pendingTunnelCopy.remove(target.id)
                report(error, as: .share)
            }
        }
    }

    func stopSharing(_ record: TunnelRecord) {
        pendingTunnelCopy.remove(record.id)
        Task {
            do {
                if record.phase.isActive { try await tunnels.stop(record.id) } else { await tunnels.dismiss(record.id) }
                await updateTunnels()
            } catch { report(error, as: .stopSharing) }
        }
    }

    func startTunnelMonitoring() {
        guard tunnelTask == nil else { return }
        tunnelTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.updateTunnels()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    func updateTunnels() async {
        let latest = await tunnels.records()
        if latest != tunnelRecords {
            withAnimation(PanelMotion.reduceMotion ? nil : PanelMotion.settle(0.20)) {
                tunnelRecords = latest
            }
        }
        for record in tunnelRecords where pendingTunnelCopy.contains(record.id) {
            if record.phase == .ready, let url = record.publicURL {
                pendingTunnelCopy.remove(record.id)
                if !isQuitting && !isSwitchingDemo {
                    copy(url.absoluteString, message: "Freigabelink kopiert", animateFeedback: true)
                }
            } else if !record.phase.isActive {
                pendingTunnelCopy.remove(record.id)
            }
        }
    }
}

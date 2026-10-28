import Foundation
import PortsCore

/// What the user tried when an error occurred. It titles the alert, so the message can stay a plain reason.
enum ErrorContext: String, Sendable {
    case generic, preferencesLoad, preferencesSave, open, start, stop, pause, resume, share, stopSharing, quit
    /// Quitting a detected agent, unlike `quit`, which is this app.
    case quitAgent

    init(_ action: ProcessAction) {
        switch action {
        case .terminate: self = .stop
        case .pause: self = .pause
        case .resume: self = .resume
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .generic: "Error"
        case .preferencesLoad: "Couldn't read settings"
        case .preferencesSave: "Settings not saved"
        case .open: "Couldn't open"
        case .start: "Couldn't start"
        case .stop: "Couldn't stop"
        case .pause: "Couldn't pause"
        case .resume: "Couldn't resume"
        case .share: "Couldn't share"
        case .stopSharing: "Sharing didn't stop"
        case .quit, .quitAgent: "Couldn't quit"
        }
    }

    /// The case label: the same in every language and safe to log publicly.
    var logKey: String { rawValue }
}

struct PanelError: Equatable {
    let context: ErrorContext
    let message: String
}

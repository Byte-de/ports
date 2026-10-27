import Foundation
import PortsCore

/// The fields a new action's form starts with.
public struct LaunchDraft: Equatable, Sendable {
    public var name: String
    public var command: String
    public var directory: String
    /// The name's placeholder, such as the project folder's name. nil leaves the generic example.
    public var suggestedName: String?

    public init(name: String = "", command: String = "", directory: String = "", suggestedName: String? = nil) {
        self.name = name
        self.command = command
        self.directory = directory
        self.suggestedName = suggestedName
    }

    /// `path` when it is an existing folder a form can start in. '/' is never a project, and a remembered folder may
    /// have been moved or deleted since.
    public static func projectDirectory(of path: String?, fileManager: FileManager = .default) -> String? {
        guard let path, path.hasPrefix("/"), path.contains(where: { $0 != "/" }) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return path
    }

    /// The folder comes from what the user asked for, then the service being inspected, then the folder of the last
    /// start. An explicit folder is kept even when it is gone, so the form says so instead of swapping in another.
    /// The folder's name becomes the name's placeholder.
    public static func prefill(
        explicit: LaunchDraft? = nil, inspected: ServiceRecord? = nil, lastDirectory: String? = nil,
        fileManager: FileManager = .default
    ) -> LaunchDraft {
        var draft = explicit ?? LaunchDraft()
        if draft.directory.isEmpty {
            draft.directory =
                projectDirectory(of: inspected?.projectDirectory, fileManager: fileManager)
                ?? projectDirectory(of: lastDirectory, fileManager: fileManager) ?? ""
        }
        if draft.suggestedName == nil, !draft.directory.isEmpty {
            draft.suggestedName = URL(fileURLWithPath: draft.directory).lastPathComponent
        }
        return draft
    }
}

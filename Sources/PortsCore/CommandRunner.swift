import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let output: String
    public let exitCode: Int32
}

/// Executes a fixed executable with argv. Never passes discovery input through a shell.
public struct CommandRunner: Sendable {
    public init() {}

    public func run(
        executable: String, arguments: [String], timeout: TimeInterval = 3,
        outputLimit: Int = 4_194_304
    ) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        pipe.fileHandleForWriting.closeFile()
        defer { pipe.fileHandleForReading.closeFile() }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        var reachedEOF = false
        while process.isRunning || !reachedEOF {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if data.count > outputLimit {
                    stop(process)
                    throw MonitorError.outputLimit
                }
            } else if count == 0 {
                reachedEOF = true
            } else if errno != EAGAIN && errno != EINTR {
                stop(process)
                throw MonitorError.scanFailed("Die Systemabfrage konnte nicht gelesen werden.")
            }
            if ProcessInfo.processInfo.systemUptime > deadline {
                stop(process)
                throw MonitorError.timedOut
            }
            if count <= 0 { Thread.sleep(forTimeInterval: 0.01) }
        }
        process.waitUntilExit()
        return CommandResult(output: String(decoding: data, as: UTF8.self), exitCode: process.terminationStatus)
    }

    private func stop(_ process: Process) {
        // Only a child created by this runner can be killed here.
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

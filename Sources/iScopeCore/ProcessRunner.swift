import Foundation
import Darwin

enum ProcessRunner {
    /// Uses arguments and stdin directly; no shell interpolation. Pipes are drained while writing stdin.
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    directory: URL? = nil, environment: [String: String]? = nil,
                    timeout: TimeInterval? = nil, maxOutputBytes: Int = 64 * 1024 * 1024,
                    workflow: Bool = false, stdoutChunk: ((Data) throws -> Void)? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments; process.currentDirectoryURL = directory
        process.environment = environment
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.standardOutput = output; process.standardError = errors
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try Task.checkCancellation()
        try process.run()
        if workflow { WorkflowProcesses.add(process) }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        try? stdin.fileHandleForReading.close()
        let outFD = output.fileHandleForReading.fileDescriptor
        let errFD = errors.fileHandleForReading.fileDescriptor
        let inFD = stdin.fileHandleForWriting.fileDescriptor
        for fd in [outFD, errFD, inFD] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        _ = fcntl(inFD, F_SETNOSIGPIPE, 1)
        var inputOpen = true, written = 0
        func closeInput() { if inputOpen { try? stdin.fileHandleForWriting.close(); inputOpen = false } }
        if input == nil { closeInput() }
        defer {
            defer { if workflow { WorkflowProcesses.remove(process) } }
            closeInput()
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                let end = ProcessInfo.processInfo.systemUptime + (workflow ? 4 : 0.3)
                while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning {
                    if workflow { kill(-process.processIdentifier, SIGKILL) }
                    kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
            }
        }
        var stdout = Data(), stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        func drain(_ fd: Int32, into data: inout Data, streaming: Bool = false) throws {
            for _ in 0..<16 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard data.count <= maxOutputBytes - count else { throw ScopeError.tool("工具输出超过大小限制。") }
                    data.append(contentsOf: buffer.prefix(count))
                    if streaming { try stdoutChunk?(Data(buffer.prefix(count))) }
                } else if count == -1 && errno == EINTR { continue }
                else { break }
            }
        }
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            try Task.checkCancellation()
            if let timeout, ProcessInfo.processInfo.systemUptime - start >= timeout { throw ScopeError.tool("工具调用超时（\(Int(timeout)) 秒），请重试。") }
            try drain(outFD, into: &stdout, streaming: true); try drain(errFD, into: &stderr)
            if inputOpen, let input {
                if written == input.count { closeInput() }
                else {
                    let count = input.withUnsafeBytes { bytes in
                        Darwin.write(inFD, bytes.baseAddress!.advanced(by: written), min(16_384, input.count - written))
                    }
                    if count > 0 { written += count }
                    else if count < 0 && errno != EAGAIN && errno != EINTR { closeInput() }
                }
            }
            if !process.isRunning {
                // Do not wait for descriptors inherited by an unrelated child process.
                for _ in 0..<max(1, maxOutputBytes / 262_144 + 1) {
                    let before = stdout.count + stderr.count
                    try drain(outFD, into: &stdout, streaming: true); try drain(errFD, into: &stderr)
                    if stdout.count + stderr.count == before { break }
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.prefix(6000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScopeError.tool(message.isEmpty ? "工具执行失败（退出码 \(process.terminationStatus)）。" : message)
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}

/// Keeps workflow processes reachable during application termination, including hidden sheets.
enum WorkflowProcesses {
    private static let lock = NSLock()
    private static var processes: [Int32: Process] = [:]
    static func add(_ process: Process) { lock.lock(); defer { lock.unlock() }; processes[process.processIdentifier] = process }
    static func remove(_ process: Process) { lock.lock(); defer { lock.unlock() }; processes.removeValue(forKey: process.processIdentifier) }
    static func stopAll() {
        lock.lock(); let active = Array(processes.values); lock.unlock()
        for process in active where process.isRunning { process.terminate() }
        let end = ProcessInfo.processInfo.systemUptime + 4
        while active.contains(where: \.isRunning), ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.02) }
        for process in active where process.isRunning { kill(-process.processIdentifier, SIGKILL); kill(process.processIdentifier, SIGKILL) }
    }
}

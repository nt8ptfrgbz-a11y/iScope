import Foundation

public enum WorkflowTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case build, package, sign, install, installExisting
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .build: return "只编译 dylib"
        case .package: return "编译并注入 IPA"
        case .sign: return "编译、注入并重签"
        case .install: return "完整流程 · 签名并安装"
        case .installExisting: return "安装已有签名 IPA"
        }
    }
}

public struct WorkflowRequest: Codable, Sendable {
    public var target: WorkflowTarget = .install
    public var projectPath = ""
    public var inputPath = ""
    public var outputDirectory = ""
    public var bundleIdentifier = ""
    public var profilePath = ""
    public var identitySHA1 = ""
    public var entitlementsPath = ""
    public var displayName = ""
    public var deviceIdentifier = ""
    public var stripExtensions = true
    public var isolateURLSchemes = false
    public var profileSearchDirectories: [String] = []
    public init() {}
}

public struct WorkflowDevice: Codable, Identifiable, Sendable {
    public let identifier: String
    public let udid: String
    public let name: String
    public var id: String { identifier }
}

public struct WorkflowIdentity: Codable, Identifiable, Sendable {
    public let fingerprint: String
    public let name: String
    public var id: String { fingerprint }
}

public struct WorkflowEnvironment: Codable, Sendable {
    public let pythonVersion: String
    public let xcodeVersion: String
    public let sdk: String
    public let identities: [WorkflowIdentity]
    public let devices: [WorkflowDevice]
    public let warnings: [String]
}

public struct WorkflowResult: Codable, Sendable {
    public let runDirectory: String
    public let dylib: String?
    public let unsignedIPA: String?
    public let signedIPA: String?
    public let installed: Bool
    public let signatureVerified: Bool
    public let bundleIdentifier: String
    public let deviceIdentifier: String?
    public let deviceName: String?
    public let removedComponents: [String]
}

public struct WorkflowEvent: Codable, Sendable {
    public let version: Int
    public let type: String
    public let stage: String?
    public let state: String?
    public let message: String?
    public let result: WorkflowResult?
    public let environment: WorkflowEnvironment?
}

/// JSON-lines framing is byte based, so UTF-8 characters split across pipe reads remain intact.
final class WorkflowEventDecoder {
    private var pending = Data()
    func append(_ chunk: Data, receive: (WorkflowEvent) -> Void) throws {
        pending.append(chunk)
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending[..<end])
            guard line.count <= 1024 * 1024 else { throw ScopeError.tool("工作流事件超过大小限制。") }
            pending.removeSubrange(...end)
            if !line.isEmpty {
                let event = try JSONDecoder().decode(WorkflowEvent.self, from: line)
                guard event.version == 1 else { throw ScopeError.tool("不支持的工作流协议版本。") }
                receive(event)
            }
        }
        guard pending.count <= 1024 * 1024 else { throw ScopeError.tool("工作流事件超过大小限制。") }
    }
    func finish() throws {
        guard pending.isEmpty else { throw ScopeError.tool("工作流返回了不完整的事件。") }
    }
}

public final class WorkflowCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var worker: Task<Void, Never>?
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; let task = worker; lock.unlock()
        task?.cancel()
    }
    fileprivate func attach(_ task: Task<Void, Never>) {
        lock.lock(); worker = task; let cancelNow = cancelled; lock.unlock()
        if cancelNow { task.cancel() }
    }
    fileprivate func detach() { lock.lock(); worker = nil; lock.unlock() }
}

private final class WorkflowBundleMarker: NSObject {}

public enum WorkflowEngine {
    public static func stopAll() { WorkflowProcesses.stopAll() }

    public static func resourceDirectory() throws -> URL {
        #if SWIFT_PACKAGE
        let bundles = [Bundle.module]
        #else
        let bundles = [Bundle.main, Bundle(for: WorkflowBundleMarker.self)]
        #endif
        for bundle in bundles {
            if let directory = bundle.url(forResource: "HookTools", withExtension: nil),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent("workflow.py").path) { return directory }
        }
        throw ScopeError.tool("App 中缺少 HookTools 资源，请重新构建或安装 iScope。")
    }

    public static func pythonExecutable(customPath: String = "") throws -> String {
        let fm = FileManager.default
        let candidates = customPath.isEmpty
            ? ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] +
                (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/python3" } + ["/usr/bin/python3"]
            : [(customPath as NSString).expandingTildeInPath]
        var seen = Set<String>()
        for path in candidates where seen.insert(path).inserted && fm.isExecutableFile(atPath: path) {
            try Task.checkCancellation()
            if (try? ProcessRunner.run(path, ["-I", "-B", "-c", "import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)"], timeout: 5)) != nil { return path }
        }
        throw ScopeError.tool("需要 Python 3.10 或更高版本。可安装 Homebrew Python，或在高级设置中指定路径。")
    }

    public static func probe(pythonPath: String = "") async throws -> WorkflowEnvironment {
        let worker = Task.detached(priority: .userInitiated) {
            var environment: WorkflowEnvironment?
            try invoke(arguments: ["probe"], pythonPath: pythonPath, timeout: 60) { if $0.type == "environment" { environment = $0.environment } }
            guard let environment else { throw ScopeError.tool("未收到环境检查结果。") }
            return environment
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    public static func events(for request: WorkflowRequest, pythonPath: String = "",
                              cancellation: WorkflowCancellation = WorkflowCancellation()) -> AsyncThrowingStream<WorkflowEvent, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task.detached(priority: .userInitiated) {
                defer { cancellation.detach() }
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iScope-workflow-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let path = directory.appendingPathComponent("request.json")
                    try JSONEncoder().encode(request).write(to: path, options: .atomic)
                    var complete = false
                    try invoke(arguments: ["run", "--request", path.path], pythonPath: pythonPath, timeout: 3600) { event in
                        if event.type == "complete" { complete = true }
                        continuation.yield(event)
                    }
                    guard complete else { throw ScopeError.tool("工作流未返回完成状态，请检查运行日志。") }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            cancellation.attach(worker)
            continuation.onTermination = { @Sendable _ in cancellation.cancel() }
        }
    }

    private static func invoke(arguments: [String], pythonPath: String, timeout: TimeInterval,
                               receive: @escaping (WorkflowEvent) -> Void) throws {
        let python = try pythonExecutable(customPath: pythonPath)
        let script = try resourceDirectory().appendingPathComponent("workflow.py")
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        let decoder = WorkflowEventDecoder()
        var reportedError: String?
        do {
            _ = try ProcessRunner.run(python, ["-I", "-B", "-u", script.path] + arguments, environment: environment,
                                      timeout: timeout, workflow: true, stdoutChunk: { chunk in
                try decoder.append(chunk) { event in
                    if event.type == "error" { reportedError = event.message }
                    receive(event)
                }
            })
            try decoder.finish()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let reportedError { throw ScopeError.tool(reportedError) }
            throw error
        }
    }
}

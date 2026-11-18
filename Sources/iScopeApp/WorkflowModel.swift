import SwiftUI
import AppKit
import iScopeCore

@MainActor
final class WorkflowModel: ObservableObject {
    @Published var request = WorkflowRequest()
    @Published var pythonPath = UserDefaults.standard.string(forKey: "workflowPythonPath") ?? "" {
        didSet { UserDefaults.standard.set(pythonPath, forKey: "workflowPythonPath") }
    }
    @Published var environment: WorkflowEnvironment?
    @Published var source = ""
    @Published var isRunning = false
    @Published var isProbing = false
    @Published var status = "选择 Hook 工程后即可开始"
    @Published var error: String?
    @Published var logs = ""
    @Published var stages: [String: String] = [:]
    @Published var result: WorkflowResult?
    @Published var selectedTab = 0
    private var savedSource = ""
    private var task: Task<Void, Never>?
    private var cancellation: WorkflowCancellation?
    private var probeTask: Task<Void, Never>?
    var isDirty: Bool { source != savedSource }
    var sourceURL: URL? {
        guard !request.projectPath.isEmpty else { return nil }
        return URL(fileURLWithPath: request.projectPath).deletingLastPathComponent().appendingPathComponent("Hooks.m")
    }
    private var configurationURL: URL? { sourceURL?.deletingLastPathComponent().appendingPathComponent("iScopeWorkflow.local.json") }

    init() {
        if let path = UserDefaults.standard.string(forKey: "workflowLastProject"), FileManager.default.fileExists(atPath: path) {
            configure(project: URL(fileURLWithPath: path), input: nil)
        }
    }

    func configure(project: URL, input: URL?) {
        guard !isRunning else { return }
        do {
            if isDirty, sourceURL != nil { try saveSource() }
            let project = project.standardizedFileURL
            let parent = project.deletingLastPathComponent()
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: parent.appendingPathComponent("HookTargets.json"))) as? [String: Any]
            guard project.pathExtension == "xcodeproj", manifest?["generator"] as? String == "iScope" else {
                throw ScopeError.invalid("请选择 iScope 生成的 .xcodeproj，需要同目录的 Hooks.m 和 HookTargets.json。")
            }
            let code = try String(contentsOf: parent.appendingPathComponent("Hooks.m"), encoding: .utf8)
            let config = parent.appendingPathComponent("iScopeWorkflow.local.json")
            var settings = (try? JSONDecoder().decode(WorkflowRequest.self, from: Data(contentsOf: config))) ?? WorkflowRequest()
            settings.projectPath = project.path
            if settings.target == .installExisting { settings.target = .install }
            if let input { settings.inputPath = input.path }
            if settings.outputDirectory.isEmpty { settings.outputDirectory = parent.appendingPathComponent("iScopeOutput").path }
            if settings.profileSearchDirectories.isEmpty {
                let previous = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/ios-hook-tools")
                settings.profileSearchDirectories = [previous.path, previous.appendingPathComponent("profiles").path]
            }
            request = settings; source = code; savedSource = code
            result = nil; stages = [:]; logs = ""; error = nil; status = "工程已就绪 · 运行前自动保存源码"
            UserDefaults.standard.set(project.path, forKey: "workflowLastProject")
        } catch { self.error = error.localizedDescription }
    }

    func chooseProject() {
        guard !isRunning else { return }
        let panel = NSOpenPanel(); panel.title = "选择 iScope Hook 工程"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.configure(project: url, input: nil) }
        }
    }

    func choosePath(_ key: WritableKeyPath<WorkflowRequest, String>, title: String, directory: Bool = false) {
        let panel = NSOpenPanel(); panel.title = title
        panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
        if key == \WorkflowRequest.inputPath { panel.canChooseDirectories = true }
        panel.canCreateDirectories = directory; panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.request[keyPath: key] = url.path }
        }
    }

    func reloadSource() {
        guard let url = sourceURL else { return }
        do { source = try String(contentsOf: url, encoding: .utf8); savedSource = source; status = "已从磁盘重新读取源码" }
        catch { self.error = error.localizedDescription }
    }

    func saveSource() throws {
        guard let url = sourceURL else { throw ScopeError.invalid("请先选择 Hook 工程。") }
        let disk = try String(contentsOf: url, encoding: .utf8)
        if disk != savedSource {
            guard !isDirty || disk == source else {
                throw ScopeError.invalid("Hooks.m 已被其他编辑器修改。请先复制当前修改，再点击“重新读取”合并，避免覆盖。")
            }
            if !isDirty { source = disk }
        }
        if source != disk { try source.write(to: url, atomically: true, encoding: .utf8) }
        savedSource = source
        try persistConfiguration()
    }

    func save() {
        do { try saveSource(); status = "源码和工程配置已保存" }
        catch { self.error = error.localizedDescription }
    }

    private func persistConfiguration() throws {
        guard let url = configurationURL else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: url, options: .atomic)
    }

    func probe() {
        guard !isProbing, !isRunning else { return }
        isProbing = true
        let pythonPath = pythonPath
        probeTask = Task {
            defer { isProbing = false }
            do {
                let value = try await WorkflowEngine.probe(pythonPath: pythonPath)
                environment = value
                if request.deviceIdentifier.isEmpty, value.devices.count == 1 { request.deviceIdentifier = value.devices[0].identifier }
            } catch { self.error = error.localizedDescription }
        }
    }

    func run(retryInstall: Bool = false) {
        guard !isRunning, !isProbing else { return }
        do {
            var execution = request
            if retryInstall {
                guard let signed = result?.signedIPA else { throw ScopeError.invalid("没有可供重试的签名 IPA。") }
                execution.target = .installExisting; execution.inputPath = signed
            } else if request.target != .installExisting { try saveSource() }
            try persistConfiguration()
            isRunning = true; error = nil; stages = [:]; logs = ""; result = nil
            status = "正在启动工作流…"; selectedTab = 1
            let pythonPath = pythonPath
            let cancellation = WorkflowCancellation(); self.cancellation = cancellation
            task = Task {
                defer { isRunning = false; self.cancellation = nil }
                do {
                    for try await event in WorkflowEngine.events(for: execution, pythonPath: pythonPath, cancellation: cancellation) {
                        consume(event)
                    }
                    status = result?.installed == true ? "安装完成 · 请在设备上启动验证 Hook" : "执行完成 · 产物已保留"
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        for key in stages.keys where stages[key] == "running" { stages[key] = "cancelled" }
                        status = "已取消 · 已完成的产物已保留"
                    } else { self.error = error.localizedDescription; status = "执行失败 · 可查看日志和已有产物" }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func consume(_ event: WorkflowEvent) {
        if let result = event.result { self.result = result }
        if event.type == "stage", let stage = event.stage {
            stages[stage] = event.state
            if let message = event.message, !message.isEmpty { status = message }
        }
        if event.type == "log", let message = event.message {
            logs += message + "\n"
            if logs.utf8.count > 250_000 { logs = "（较早日志请查看 workflow.log）\n" + String(logs.suffix(160_000)) }
        }
        if event.type == "error" { error = event.message }
    }

    func cancel() { status = "正在取消并清理子进程…"; cancellation?.cancel() }
}

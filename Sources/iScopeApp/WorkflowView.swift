import SwiftUI
import AppKit
import iScopeCore

struct WorkflowView: View {
    @ObservedObject var model: WorkflowModel
    @Environment(\.dismiss) private var dismiss
    @State private var showAdvanced = false
    @State private var confirmReload = false
    private let stages = [("preflight", "预检"), ("build", "编译"), ("package", "注入打包"), ("sign", "重签验证"), ("install", "安装")]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill").font(.title).foregroundStyle(ScopeTheme.accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Hook 编译与部署").font(.title3.bold())
                    Text("修改实现，然后自动编译、注入、重签并安装到真机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if let error = model.error, model.selectedTab == 0 {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(10)
            }
            HSplitView {
                ScrollView { configuration.padding(18) }.frame(minWidth: 330, idealWidth: 360, maxWidth: 430)
                VStack(spacing: 0) {
                    Picker("内容", selection: $model.selectedTab) {
                        Text("编辑 Hooks.m").tag(0); Text("执行日志与产物").tag(1)
                    }.pickerStyle(.segmented).padding(12)
                    if model.selectedTab == 0 { editor } else { output }
                }.frame(minWidth: 500)
            }
            Divider()
            HStack {
                if model.isRunning { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).lineLimit(2)
                Spacer()
                if model.isRunning { Button("取消执行", action: model.cancel) }
                else {
                    if model.result?.signedIPA != nil {
                        Button("仅重试安装") { model.run(retryInstall: true) }.disabled(model.isProbing)
                    }
                    Button("开始执行") { model.run() }.buttonStyle(.borderedProminent)
                        .disabled(model.isProbing || (model.request.target != .installExisting && model.request.projectPath.isEmpty))
                }
            }.padding(16)
        }
        .frame(width: 1060, height: 810)
        .tint(ScopeTheme.accent)
        .onAppear { if model.environment == nil { model.probe() } }
        .alert("重新读取源码？", isPresented: $confirmReload) {
            Button("取消", role: .cancel) {}
            Button("读取磁盘版本", role: .destructive, action: model.reloadSource)
        } message: { Text("当前未保存的编辑将被磁盘上的 Hooks.m 替换。") }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("输入与执行目标").font(.headline)
            pathRow("Hook 工程", value: model.request.projectPath, action: model.chooseProject)
            pathRow(model.request.target == .installExisting ? "已签名 IPA" : "原始 IPA / .app", value: model.request.inputPath) {
                model.choosePath(\WorkflowRequest.inputPath, title: "选择 IPA 或 .app")
            }
            Picker("执行到", selection: $model.request.target) {
                ForEach(WorkflowTarget.allCases) { Text($0.title).tag($0) }
            }
            pathRow("输出目录", value: model.request.outputDirectory) {
                model.choosePath(\WorkflowRequest.outputDirectory, title: "选择输出目录", directory: true)
            }
            Text("每次执行使用独立目录，保留构建副本、产物和完整日志。").font(.caption2).foregroundStyle(.secondary)
            Divider()
            Text("签名与设备").font(.headline)
            TextField("重签 Bundle ID（留空自动）", text: $model.request.bundleIdentifier).textFieldStyle(.roundedBorder)
            Text("重签默认追加 .regisn；只编译 / 注入默认保留原 ID。Hook 过滤条件会在构建副本中同步适配。")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("App 显示名称（留空保留）", text: $model.request.displayName).textFieldStyle(.roundedBorder)
            Picker("证书", selection: $model.request.identitySHA1) {
                Text("自动匹配本机证书").tag("")
                ForEach(model.environment?.identities ?? []) { Text($0.name).tag($0.fingerprint) }
                if !model.request.identitySHA1.isEmpty && !(model.environment?.identities.contains { $0.fingerprint == model.request.identitySHA1 } ?? false) {
                    Text("已保存证书（未检测到）").tag(model.request.identitySHA1)
                }
            }
            Picker("真机", selection: $model.request.deviceIdentifier) {
                Text("自动选择唯一已连接真机").tag("")
                ForEach(model.environment?.devices ?? []) { Text($0.name).tag($0.identifier) }
                if !model.request.deviceIdentifier.isEmpty && !(model.environment?.devices.contains { $0.identifier == model.request.deviceIdentifier } ?? false) {
                    Text("已保存设备（未连接）").tag(model.request.deviceIdentifier)
                }
            }
            Text("描述文件会从 Xcode、IPA / 工程同目录和原 ios-hook-tools 目录自动匹配，也可在高级设置中指定。")
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("刷新环境与设备", action: model.probe).disabled(model.isProbing)
                if model.isProbing { ProgressView().controlSize(.small) }
            }
            if let environment = model.environment {
                Text("Python \(environment.pythonVersion) · \(environment.xcodeVersion.replacingOccurrences(of: "\n", with: " · "))")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(environment.warnings, id: \.self) { Text($0).font(.caption2).foregroundStyle(.orange) }
            }
            DisclosureGroup("高级设置", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    pathRow("描述文件 · 留空自动匹配", value: model.request.profilePath) {
                        model.choosePath(\WorkflowRequest.profilePath, title: "选择 mobileprovision 描述文件")
                    }
                    if !model.request.profilePath.isEmpty { Button("恢复自动匹配") { model.request.profilePath = "" }.font(.caption) }
                    pathRow("额外 Entitlements（可选）", value: model.request.entitlementsPath) {
                        model.choosePath(\WorkflowRequest.entitlementsPath, title: "选择 Entitlements plist")
                    }
                    if !model.request.entitlementsPath.isEmpty { Button("清除额外权限") { model.request.entitlementsPath = "" }.font(.caption) }
                    Toggle("移除 App 扩展、Watch 与 App Clips", isOn: $model.request.stripExtensions)
                    Text("默认用主 App 的描述文件签名；保留扩展需要独立签名配置，当前不支持。关闭后遇到扩展会明确报错。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Toggle("隔离 URL Schemes", isOn: $model.request.isolateURLSchemes)
                    Text("为副本的 URL Scheme 加前缀，避免与原 App 冲突；可能影响回调和登录。")
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("Python 3.10+ 路径（留空自动）", text: $model.pythonPath).textFieldStyle(.roundedBorder)
                }.padding(.top, 10)
            }
        }.disabled(model.isRunning)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.isDirty ? "Hooks.m · 未保存" : "Hooks.m").font(.caption)
                Spacer()
                Button("重新读取") { if model.isDirty { confirmReload = true } else { model.reloadSource() } }
                Button("保存", action: model.save).keyboardShortcut("s")
                Button("用 Xcode 打开") { NSWorkspace.shared.open(URL(fileURLWithPath: model.request.projectPath)) }
            }.padding(.horizontal, 12).padding(.bottom, 10).disabled(model.isRunning || model.sourceURL == nil)
            if model.sourceURL == nil {
                ContentUnavailableView("选择 Hook 工程", systemImage: "curlybraces", description: Text("从分析结果生成工程，或打开已有的 iScope 工程。"))
            } else {
                TextEditor(text: $model.source).font(.system(size: 11, design: .monospaced))
                    .disableAutocorrection(true).disabled(model.isRunning)
            }
        }
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 15) {
                ForEach(stages, id: \.0) { key, name in
                    Label(name, systemImage: stageIcon(model.stages[key]))
                        .foregroundStyle(stageColor(model.stages[key])).font(.caption)
                }
            }.padding(.horizontal, 14)
            if let error = model.error {
                ScrollView { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 95).padding(.horizontal, 14)
            }
            if let result = model.result {
                VStack(alignment: .leading, spacing: 8) {
                    artifactRow("dylib", path: result.dylib)
                    artifactRow("未签名 IPA", path: result.unsignedIPA)
                    artifactRow(result.signatureVerified ? "签名 IPA · 已复验" : "签名 IPA", path: result.signedIPA)
                    HStack {
                        Button("打开本次输出目录") { NSWorkspace.shared.open(URL(fileURLWithPath: result.runDirectory)) }
                        if result.installed { Label("已安装到 \(result.deviceName ?? "真机")", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    }.font(.caption)
                    if !result.removedComponents.isEmpty {
                        Text("签名副本中已移除：" + result.removedComponents.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(ScopeTheme.panel).padding(.horizontal, 12)
            }
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.logs.isEmpty ? "执行日志会显示在这里。" : model.logs).textSelection(.enabled)
                            .font(.system(size: 10, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("tail")
                    }.padding(12)
                }.background(ScopeTheme.canvas)
                    .onChange(of: model.logs) { _, _ in proxy.scrollTo("tail", anchor: .bottom) }
            }
        }.padding(.top, 8)
    }

    private func pathRow(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium))
            HStack {
                Text(value.isEmpty ? "未选择" : value).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(value.isEmpty ? .tertiary : .secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 4)
                Button("选择…", action: action).controlSize(.small)
            }
        }
    }

    @ViewBuilder private func artifactRow(_ title: String, path: String?) -> some View {
        if let path {
            HStack {
                Text(title).font(.caption.weight(.medium))
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.controlSize(.mini)
            }
        }
    }
    private func stageIcon(_ state: String?) -> String {
        switch state {
        case "running": return "arrow.triangle.2.circlepath"
        case "done": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        case "cancelled": return "stop.circle"
        case "skipped": return "minus.circle"
        default: return "circle"
        }
    }
    private func stageColor(_ state: String?) -> Color {
        switch state { case "done": return .green; case "failed": return .red; case "running": return ScopeTheme.accent; default: return .secondary }
    }
}

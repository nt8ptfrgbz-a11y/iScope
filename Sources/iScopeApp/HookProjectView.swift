import SwiftUI
import AppKit
import iScopeCore

struct HookProjectView: View {
    struct Candidate: Identifiable {
        let method: ObjCMethod
        let image: String
        let reason: String?
        var id: String { "\(HookProjectGenerator.targetClassName(method))|\(method.isClassMethod)|\(method.selector)" }
    }
    @Environment(\.dismiss) private var dismiss
    private let candidates: [Candidate]
    private let continueWorkflow: (URL) -> Void
    @State private var projectName = "IScopeHook"
    @State private var bundleID: String
    @State private var selected: Set<String>
    @State private var filter = ""
    @State private var source = ""
    @State private var validationError: String?
    @State private var writeError: String?
    @State private var createdURL: URL?
    @State private var isWriting = false
    @State private var previewTab = 0

    init(analyses: [BinaryAnalysis], bundleIdentifier: String, seeds: [ObjCMethod], continueWorkflow: @escaping (URL) -> Void) {
        self.continueWorkflow = continueWorkflow
        var seen = Set<String>()
        var items: [Candidate] = []
        for analysis in analyses {
            for method in analysis.methods {
                let reason: String?
                do { _ = try HookProjectGenerator.signature(for: method); reason = nil }
                catch { reason = error.localizedDescription }
                let item = Candidate(method: method, image: analysis.image.name, reason: reason)
                if seen.insert(item.id).inserted { items.append(item) }
            }
        }
        candidates = items.sorted { $0.method.signature.localizedStandardCompare($1.method.signature) == .orderedAscending }
        _bundleID = State(initialValue: bundleIdentifier)
        let seedIDs = Set(seeds.map { "\(HookProjectGenerator.targetClassName($0))|\($0.isClassMethod)|\($0.selector)" })
        _selected = State(initialValue: Set(items.filter { seedIDs.contains($0.id) && $0.reason == nil }.map(\.id)))
    }

    private var configuration: HookProjectConfiguration {
        HookProjectConfiguration(name: projectName, bundleIdentifier: bundleID,
                                 methods: candidates.filter { selected.contains($0.id) }.map(\.method))
    }
    private var visibleCandidates: [Candidate] {
        candidates.filter { filter.isEmpty || $0.method.signature.localizedCaseInsensitiveContains(filter) || $0.image.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            heading
            Divider()
            if let createdURL { success(createdURL) }
            else {
                configurationForm
                Divider()
                HSplitView {
                    methodPicker.frame(minWidth: 300, idealWidth: 340)
                    preview.frame(minWidth: 390)
                }
            }
            Divider()
            footer
        }
        .frame(width: 940, height: 740)
        .tint(ScopeTheme.accent)
        .onAppear(perform: refreshPreview)
        .onChange(of: selected) { _, _ in refreshPreview() }
        .onChange(of: projectName) { _, _ in refreshPreview() }
        .onChange(of: bundleID) { _, _ in refreshPreview() }
        .alert("创建工程失败", isPresented: Binding(get: { writeError != nil }, set: { if !$0 { writeError = nil } })) {
            Button("好") { writeError = nil }
        } message: { Text(writeError ?? "") }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "hammer.fill").font(.system(size: 25)).foregroundStyle(ScopeTheme.accent)
                .frame(width: 45, height: 45).background(ScopeTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text("创建 Xcode Hook 工程").font(.system(size: 19, weight: .semibold))
                Text("选方法，改实现。自动生成可编译的 iOS 动态库项目。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            SmallBadge(text: "iOS dylib · arm64", color: ScopeTheme.accent)
        }.padding(22)
    }

    private var configurationForm: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text("工程名").font(.system(size: 11, weight: .medium))
                TextField("IScopeHook", text: $projectName).textFieldStyle(.roundedBorder)
                Text("英文字母、数字和下划线").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.frame(width: 250)
            VStack(alignment: .leading, spacing: 7) {
                Text("目标 Bundle ID").font(.system(size: 11, weight: .medium))
                TextField("com.example.app", text: $bundleID).textFieldStyle(.roundedBorder)
                Text("已从 IPA 自动读取，也可手动修改；动态库只在匹配的应用中安装 Hook。")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }.frame(maxWidth: .infinity)
        }.padding(.horizontal, 22).padding(.vertical, 16).disabled(isWriting)
    }

    private var methodPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("选择方法").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("已选 \(selected.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                Menu {
                    Button("选择筛选结果中可生成的方法") { selected.formUnion(visibleCandidates.filter { $0.reason == nil }.map(\.id)) }
                    Button("清空选择") { selected.removeAll() }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(14)
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("筛选类名、方法名或 Mach-O…", text: $filter).textFieldStyle(.plain)
            }.font(.system(size: 11)).padding(9).background(ScopeTheme.panel, in: RoundedRectangle(cornerRadius: 7)).padding(.horizontal, 12).padding(.bottom, 10)
            List(visibleCandidates) { candidate in
                Toggle(isOn: Binding(get: { selected.contains(candidate.id) }, set: { value in
                    if value { selected.insert(candidate.id) } else { selected.remove(candidate.id) }
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(candidate.method.signature).font(.system(size: 10, design: .monospaced)).lineLimit(2)
                        Text(candidate.reason ?? candidate.image).font(.system(size: 9)).foregroundStyle(candidate.reason == nil ? Color.secondary : .orange).lineLimit(2)
                    }.padding(.vertical, 4)
                }.toggleStyle(.checkbox).disabled(candidate.reason != nil || isWriting)
            }.listStyle(.plain)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("预览", selection: $previewTab) { Text("Hooks.m").tag(0); Text("使用说明").tag(1) }.pickerStyle(.segmented).frame(width: 210)
                Spacer()
                if !source.isEmpty {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).help("复制代码预览")
                }
            }.padding(12)
            Divider()
            if previewTab == 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        instruction("1", "创建工程", "生成后点击“继续编译与部署”，也可以用 Xcode 打开 .xcodeproj。")
                        instruction("2", "修改 Hooks.m", "每个方法都有独立的替换函数。默认调用原实现，你可以修改参数、返回值或添加自己的逻辑。")
                        instruction("3", "选择执行目标", "在 iScope 内选择只编译、注入、重签或完整安装流程。")
                        instruction("4", "自动部署", "连接真机，选择证书与描述文件或自动匹配，点击开始执行。")
                        Text("支持 Objective-C runtime 方法与常见 UIKit 结构体。无法自动还原可靠签名的方法会禁用；纯 Swift 非 @objc 方法需要其他 Hook 方式。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                    }.padding(20)
                }
            } else if let validationError {
                ContentUnavailableView("完善工程配置", systemImage: "curlybraces", description: Text(validationError))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(source).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).lineSpacing(3).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.background(ScopeTheme.canvas)
            }
        }
    }

    private var footer: some View {
        HStack {
            if isWriting { ProgressView().controlSize(.small); Text("正在生成工程…").font(.system(size: 11)).foregroundStyle(.secondary) }
            else if createdURL == nil { Text("工程包含源码、方法清单和共享 Scheme，无需安装 Theos。").font(.system(size: 10)).foregroundStyle(.secondary) }
            Spacer()
            Button(createdURL == nil ? "取消" : "完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isWriting)
            if createdURL == nil {
                Button("创建工程…", action: chooseDestination).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(validationError != nil || isWriting)
            }
        }.padding(18)
    }

    private func success(_ url: URL) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 48)).foregroundStyle(ScopeTheme.green)
            Text("Hook 工程已创建").font(.system(size: 22, weight: .semibold))
            Text("继续到部署面板，在 App 内修改 Hooks.m 并完成编译、注入、重签和安装。").font(.system(size: 13)).foregroundStyle(.secondary)
            Text(url.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 12) {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("用 Xcode 打开") { NSWorkspace.shared.open(url.appendingPathComponent(projectName + ".xcodeproj")) }
                Button("继续编译与部署") { continueWorkflow(url.appendingPathComponent(projectName + ".xcodeproj")) }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func instruction(_ number: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(ScopeTheme.accent).frame(width: 23, height: 23).background(ScopeTheme.accent.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 12, weight: .semibold)); Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4) }
        }
    }

    private func refreshPreview() {
        do { source = try HookProjectGenerator.source(configuration); validationError = nil }
        catch { source = ""; validationError = error.localizedDescription }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "选择 Hook 工程的保存目录"
        panel.message = "将在此目录内创建 \(projectName) 文件夹。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "创建工程"
        let configuration = configuration
        panel.begin { response in
            guard response == .OK, let parent = panel.url else { return }
            Task { @MainActor in
                isWriting = true
                let worker = Task.detached(priority: .userInitiated) {
                    let access = parent.startAccessingSecurityScopedResource()
                    defer { if access { parent.stopAccessingSecurityScopedResource() } }
                    return try HookProjectGenerator.write(configuration, to: parent)
                }
                do { createdURL = try await worker.value }
                catch { writeError = error.localizedDescription }
                isWriting = false
            }
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers
import iScopeCore

struct WorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.artifact == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    SidebarView().navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                } content: {
                    VStack(spacing: 0) {
                        searchBar
                        Divider()
                        if model.page == .overview { OverviewView() }
                        else { SearchResultsView() }
                    }
                    .navigationSplitViewColumnWidth(min: 380, ideal: 650)
                } detail: {
                    InspectorView().frame(minWidth: 300, idealWidth: 350)
                }
                .navigationSplitViewStyle(.balanced)
            }
            Divider()
            statusBar
        }
        .background(ScopeTheme.canvas)
        .tint(ScopeTheme.accent)
        .navigationTitle(model.artifact?.name ?? "iScope")
        .toolbar { toolbar }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: acceptDrop)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12).fill(ScopeTheme.accent.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ScopeTheme.accent, style: StrokeStyle(lineWidth: 3, dash: [8])))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $model.showExport) { ExportSheet() }
        .sheet(isPresented: $model.showCodexSettings) { CodexSettingsView() }
        .sheet(isPresented: $model.showWorkflow) { WorkflowView(model: model.workflow) }
        .sheet(isPresented: $model.showHookProject, onDismiss: {
            if model.pendingWorkflow { model.pendingWorkflow = false; model.showWorkflow = true }
        }) {
            HookProjectView(analyses: model.hookAnalyses, bundleIdentifier: model.artifact?.bundleIdentifier ?? "", seeds: model.hookSeeds) { project in
                model.workflow.configure(project: project, input: model.artifact?.sourceURL)
                model.pendingWorkflow = true; model.showHookProject = false
            }
        }
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(ScopeTheme.accent)
                TextField("搜索功能、类名、Selector、字符串或地址…", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 14)).focused($searchFocused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain)
                }
                Text("⌘ F").font(.system(size: 10)).foregroundStyle(.tertiary)
                Button(action: model.startSmartSearch) { Label("智能定位", systemImage: "sparkle.magnifyingglass") }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(!model.canSmartSearch)
                    .help("用 Codex 理解描述，再在当前范围的真实分析结果中查找候选方法")
            }
            .padding(12).background(ScopeTheme.panel, in: RoundedRectangle(cornerRadius: 9))
            HStack(spacing: 12) {
                Menu {
                    Button("当前 Mach-O") { model.searchAllImages = false }
                    Button("全部已分析 Mach-O（\(model.analyses.count)）") { model.searchAllImages = true }
                } label: {
                    Label(model.searchAllImages ? "全部已分析 Mach-O" : "当前 Mach-O", systemImage: model.searchAllImages ? "square.stack.3d.up" : "doc")
                        .font(.system(size: 11))
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Toggle("Aa", isOn: $model.caseSensitive).disabled(model.isSmartMode).help("区分大小写（关键词搜索）")
                Toggle(".*", isOn: $model.useRegex).disabled(model.isSmartMode).help("正则表达式（关键词搜索）")
                Toggle("功能词扩展", isOn: $model.expandFeatures).disabled(model.useRegex || model.isSmartMode).help("将“登录”“支付”等中文词扩展为常见英文关键词")
            }
            .toggleStyle(.button).font(.system(size: 10, weight: .medium))
        }.padding(16)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: model.openPanel) { Label("导入", systemImage: "square.and.arrow.down") }.help("导入 IPA 或 Mach-O（⌘O）")
            Button { model.showCodexSettings = true } label: { Label("Codex 设置", systemImage: "slider.horizontal.3") }
            Button { model.showWorkflow = true } label: { Label("编译与部署", systemImage: "shippingbox") }
            if model.artifact != nil {
                Button { model.createHookProject() } label: { Label("创建 Hook 工程", systemImage: "hammer") }
                    .disabled(!model.orderedAnalyses.contains { !$0.methods.isEmpty })
                Button { model.analyzeAll() } label: { Label("分析全部", systemImage: "square.stack.3d.up.badge.a.fill") }.disabled(!model.canAnalyzeAll)
                Button { model.showExport = true } label: { Label("导出", systemImage: "square.and.arrow.up") }.disabled(model.analyses.isEmpty)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isWorking { ProgressView().controlSize(.mini); Text(model.progress) }
            else { Circle().fill(ScopeTheme.green).frame(width: 5, height: 5); Text(model.artifact == nil ? "准备就绪" : model.progress) }
            if model.isWorking { Button("取消", action: model.cancelWork).buttonStyle(.link) }
            Spacer()
            WorkflowStatusButton(model: model.workflow) { model.showWorkflow = true }
            if let toast = model.toast { Label(toast, systemImage: "checkmark.circle.fill").foregroundStyle(ScopeTheme.green) }
            if let artifact = model.artifact { Text("\(model.analyses.count)/\(artifact.images.count) 个 Mach-O 已分析"); Text("·") }
            Label("本地静态分析", systemImage: "externaldrive")
        }
        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 29).background(.bar)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.open(url) }
        }
        return true
    }
}

private struct WorkflowStatusButton: View {
    @ObservedObject var model: WorkflowModel
    let action: () -> Void
    var body: some View {
        if model.isRunning {
            Button(action: action) { Label(model.status, systemImage: "shippingbox").lineLimit(1) }.buttonStyle(.link)
        }
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var imageFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "scope").font(.system(size: 23, weight: .medium)).foregroundStyle(ScopeTheme.accent)
                    .frame(width: 42, height: 42).background(ScopeTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.artifact?.name ?? "iScope").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(model.artifact?.bundleIdentifier ?? "Mach-O 工作空间").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }.padding(16)
            List {
                Section("工作空间") {
                    ForEach(WorkspacePage.allCases) { page in
                        Button { model.page = page } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.icon).frame(width: 18).foregroundStyle(model.page == page ? ScopeTheme.accent : .secondary)
                                Text(page.title)
                                Spacer()
                                if let count = count(for: page), count > 0 { Text(count.formatted()).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                            }
                            .font(.system(size: 12)).padding(.vertical, 5).padding(.horizontal, 7).contentShape(Rectangle())
                            .background(model.page == page ? ScopeTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    }
                }
                Section {
                    HStack {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                        TextField("筛选 Mach-O", text: $imageFilter).textFieldStyle(.plain)
                    }.font(.system(size: 11)).padding(.vertical, 5)
                    ForEach((model.artifact?.images ?? []).filter { imageFilter.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(imageFilter) }) { image in
                        imageRow(image)
                    }
                } header: {
                    HStack { Text("Mach-O 文件"); Spacer(); Text("\(model.artifact?.images.count ?? 0)") }
                }
            }.listStyle(.sidebar)
        }.background(.bar)
    }

    private func imageRow(_ image: BinaryImage) -> some View {
        Button { model.selectedImageID = image.id } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: image.isMainExecutable ? "app.badge" : "shippingbox").foregroundStyle(image.isMainExecutable ? ScopeTheme.accent : .secondary).frame(width: 17).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(image.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(image.architectures.joined(separator: " · ")).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.analyses[image.id] != nil { Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(ScopeTheme.green) }
            }
            .padding(8).contentShape(Rectangle())
            .background(model.selectedImageID == image.id ? ScopeTheme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).disabled(model.isWorking).help(image.relativePath)
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
    }

    private func count(for page: WorkspacePage) -> Int? {
        switch page {
        case .methods: return model.currentAnalysis?.methods.count
        case .classes: return model.currentAnalysis?.classes.count
        case .strings: return model.currentAnalysis?.strings.count
        case .symbols: return model.currentAnalysis?.symbols.count
        case .bookmarks: return model.bookmarks.count
        default: return nil
        }
    }
}

private struct ExportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var format = ExportFormat.methods
    @State private var all = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("导出分析结果", systemImage: "square.and.arrow.up").font(.title2.weight(.semibold))
            Text("导出保留文件名、架构和地址，便于继续在 Hopper、IDA 或其他工具中定位。").font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("内容", selection: $format) { ForEach(ExportFormat.allCases) { Text($0.title).tag($0) } }
                Picker("范围", selection: $all) {
                    Text("当前 Mach-O").tag(false)
                    Text("全部已分析文件（\(model.analyses.count)）").tag(true)
                }
            }
            if format == .headers { Text("接口草稿来自运行时元数据，参数名使用占位符。Swift 原生类型无法完整还原成 Objective-C 头文件。").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("选择保存位置…") { dismiss(); model.export(format: format, all: all) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!all && model.currentAnalysis == nil)
            }
        }.padding(28).frame(width: 510)
    }
}

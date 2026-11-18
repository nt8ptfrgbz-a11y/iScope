import SwiftUI
import iScopeCore

struct OverviewView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let analysis = model.currentAnalysis {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(analysis)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        stat("类与 Category", count: analysis.classes.count, icon: "square.stack.3d.up", color: ScopeTheme.purple, page: .classes)
                        stat("Objective-C 方法", count: analysis.methods.count, icon: "function", color: ScopeTheme.accent, page: .methods)
                        stat("字符串", count: analysis.strings.count, icon: "text.quote", color: ScopeTheme.green, page: .strings)
                        stat("符号", count: analysis.symbols.count, icon: "number", color: .orange, page: .symbols)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Label("从功能开始探索", systemImage: "scope").font(.system(size: 14, weight: .semibold))
                        Text("输入“微信运动步数”这样的描述，点击“智能定位”，让 Codex 生成检索计划并筛选候选；也可直接用关键词在本地搜索。").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                        HStack(spacing: 8) {
                            ForEach(["登录", "支付", "会员", "消息", "视频"], id: \.self) { word in
                                Button(word) { model.page = .all; model.query = word }.buttonStyle(.bordered)
                            }
                        }.font(.system(size: 11))
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ScopeTheme.accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("文件信息").font(.system(size: 13, weight: .semibold))
                        metadata("路径", analysis.image.relativePath)
                        metadata("大小", ByteCountFormatter.string(fromByteCount: Int64(analysis.image.size), countStyle: .file))
                        metadata("UUID", analysis.uuid ?? "未提供")
                        metadata("Image base", analysis.imageBase.hex)
                        metadata("静态引用", "\(analysis.references.count.formatted()) 处 · 名称搜索与静态引用不代表运行时执行")
                        metadata("分析耗时", String(format: "%.2f 秒", analysis.elapsed))
                    }
                    if !analysis.warnings.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(analysis.warnings, id: \.self) { Text("• " + $0).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                            }.padding(.top, 10)
                        } label: { Label("解析范围与提示（\(analysis.warnings.count)）", systemImage: "info.circle").font(.system(size: 12)) }
                    }
                    if !analysis.dependencies.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(analysis.dependencies, id: \.self) { Text($0).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                            }.padding(.top, 10)
                        } label: { Label("依赖库（\(analysis.dependencies.count)）", systemImage: "shippingbox").font(.system(size: 12)) }
                    }
                }.padding(24)
            }
        } else {
            ContentUnavailableView {
                Label(model.isWorking ? "正在分析" : "选择一个 Mach-O", systemImage: "waveform.path")
            } description: { Text(model.isWorking ? model.progress : "从左侧选择文件开始分析。") } actions: {
                if !model.isWorking { Button("分析当前文件") { model.analyzeSelected() }.buttonStyle(.borderedProminent) }
            }
        }
    }

    private func header(_ analysis: BinaryAnalysis) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.richtext").font(.system(size: 25)).foregroundStyle(ScopeTheme.accent).frame(width: 44, height: 48)
            VStack(alignment: .leading, spacing: 7) {
                Text(analysis.image.name).font(.system(size: 23, weight: .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    SmallBadge(text: analysis.architecture, color: ScopeTheme.accent)
                    SmallBadge(text: analysis.encrypted ? "存在加密标记" : "无加密标记", color: analysis.encrypted ? .orange : ScopeTheme.green)
                    if analysis.image.isMainExecutable { SmallBadge(text: "主程序") }
                }
            }
            Spacer(minLength: 0)
            if analysis.image.architectures.count > 1 {
                Menu {
                    ForEach(analysis.image.architectures, id: \.self) { architecture in
                        Button(architecture) { model.analyzeSelected(architecture: architecture) }
                    }
                } label: { Image(systemName: "cpu") }.menuStyle(.borderlessButton).fixedSize().disabled(model.isWorking).help("切换分析架构")
            }
        }
    }

    private func stat(_ title: String, count: Int, icon: String, color: Color, page: WorkspacePage) -> some View {
        Button { model.page = page } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Image(systemName: icon).foregroundStyle(color); Text(title).foregroundStyle(.secondary); Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) }.font(.system(size: 11))
                Text(count.formatted()).font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(.primary)
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .background(ScopeTheme.panel, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.04)))
        }.buttonStyle(.plain)
    }

    private func metadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 11)).lineSpacing(3)
    }
}

struct SearchResultsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if model.page == .all && !model.featureSearchSessions.isEmpty { FeatureSearchTabs() }
            HStack(spacing: 8) {
                Text(model.page.title).font(.system(size: 13, weight: .semibold))
                Text(model.resultCount.formatted()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                if model.isSearching { ProgressView().controlSize(.mini) }
                if model.resultCount > model.results.count { Text(model.isSmartMode ? "优先展示 \(model.results.count) 个候选" : "显示前 \(model.results.count) 条，请缩小搜索范围").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 18).padding(.vertical, 13)
            if model.isSmartMode { SmartSearchPanel() }
            if !model.expandedTerms.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkle.magnifyingglass").foregroundStyle(ScopeTheme.accent)
                    Text("扩展：" + model.expandedTerms.joined(separator: " · ")).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }.font(.system(size: 10)).padding(.horizontal, 18).padding(.bottom, 12)
            }
            if model.searchAllImages && model.analyses.count < (model.artifact?.images.count ?? 0) {
                HStack {
                    Text("当前搜索覆盖 \(model.analyses.count)/\(model.artifact?.images.count ?? 0) 个文件").foregroundStyle(.secondary)
                    Spacer()
                    Button("分析全部") { model.analyzeAll() }.buttonStyle(.link).disabled(!model.canAnalyzeAll)
                }.font(.system(size: 10)).padding(.horizontal, 18).padding(.bottom, 10)
            }
            Divider()
            if let error = model.searchError {
                ContentUnavailableView("搜索表达式有误", systemImage: "exclamationmark.magnifyingglass", description: Text(error))
            } else if model.results.isEmpty && !model.isSearching && !model.isSmartSearching {
                ContentUnavailableView {
                    Label(model.page == .bookmarks ? "还没有收藏" : "没有匹配结果", systemImage: model.page == .bookmarks ? "bookmark" : "magnifyingglass")
                } description: {
                    Text(model.isSmartMode ? "当前范围内还没有足够的函数线索。可查看文本线索、细化动作，或分析其他 Mach-O 后再次定位。" : model.page == .bookmarks ? "选中结果后点击右侧收藏按钮，保留方法和分析笔记。" : "尝试更短的关键词、英文名称或字符串。名称被混淆时，可先查找界面文案和 API 路径。")
                }
            } else {
                ScrollViewReader { proxy in
                    List(selection: $model.selectedResultID) {
                        ForEach(model.results) { result in
                            ResultRow(result: result).tag(result.id).id(result.id)
                                .contextMenu {
                                    Button("复制名称") { model.copy(result.title) }
                                    Button("复制地址") { model.copy(result.address.hex) }
                                    if result.kind == .method || result.kind == .classInfo {
                                        Button("创建 Hook 工程…") { model.createHookProject(from: result) }
                                    }
                                    Button(model.bookmarks.contains(result.id) ? "取消收藏" : "收藏") { model.toggleBookmark(result) }
                                }
                        }
                    }.listStyle(.plain).alternatingRowBackgrounds(.disabled)
                    .onAppear {
                        if let selected = model.selectedResultID { proxy.scrollTo(selected, anchor: .center) }
                    }
                    .id(model.resultListIdentity)
                }
            }
        }
    }
}

private struct ResultRow: View {
    @EnvironmentObject private var model: AppModel
    let result: SearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TypeIcon(kind: result.kind).padding(.top, 2)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(result.title.replacingOccurrences(of: "\n", with: " ↵ ")).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                    if model.bookmarks.contains(result.id) { Image(systemName: "bookmark.fill").font(.system(size: 9)).foregroundStyle(ScopeTheme.accent) }
                }
                HStack(spacing: 5) {
                    Text(result.imageName).lineLimit(1)
                    Text("·")
                    Text(result.address.hex).fontDesign(.monospaced)
                    Spacer(minLength: 0)
                    if let evidence = result.evidence.first { Text(evidence).foregroundStyle(ScopeTheme.color(result.kind)).lineLimit(1) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if let assessment = model.assessment(for: result) {
                    Text("Codex · \(assessment.relevance == .likely ? "优先核查" : assessment.relevance == .possible ? "可能相关" : "线索较弱")：\(assessment.reason)")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 8).padding(.horizontal, 5)
    }
}

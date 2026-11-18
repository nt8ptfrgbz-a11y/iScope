import SwiftUI
import iScopeCore

struct InspectorView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let result = model.selectedResult, let analysis = model.selectedAnalysis {
            ResultInspector(result: result, analysis: analysis).id(result.id)
        } else {
            VStack(spacing: 19) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(ScopeTheme.accent.opacity(0.6))
                Text("让线索连起来").font(.system(size: 16, weight: .medium))
                Text("选中一个类、方法或字符串，\n查看接口、地址与静态引用。").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
                VStack(alignment: .leading, spacing: 14) {
                    guide("1", "搜索功能词或界面文案")
                    guide("2", "查看命中依据和引用方法")
                    guide("3", "复制地址，继续深入分析")
                }.padding(18).background(ScopeTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24).background(ScopeTheme.canvas)
        }
    }
    private func guide(_ number: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(number).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(ScopeTheme.accent)
                .frame(width: 20, height: 20).background(ScopeTheme.accent.opacity(0.09), in: Circle())
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

private struct ResultInspector: View {
    @EnvironmentObject private var model: AppModel
    let result: SearchResult
    let analysis: BinaryAnalysis
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    SmallBadge(text: result.kind.title, color: ScopeTheme.color(result.kind))
                    Spacer()
                    Button { model.copy(result.title) } label: { Image(systemName: "doc.on.doc") }.help("复制名称")
                    Button { model.toggleBookmark(result) } label: { Image(systemName: model.bookmarks.contains(result.id) ? "bookmark.fill" : "bookmark") }.help("收藏")
                }.buttonStyle(.borderless)
                Text(result.title).font(.system(size: 15, weight: .semibold, design: .monospaced)).textSelection(.enabled).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                InspectorSection(title: "位置") {
                    detail("Mach-O", result.imageName)
                    detail("架构", analysis.architecture)
                    detail("虚拟地址", result.address.hex)
                    if let offset = fileOffset { detail("文件偏移", offset.hex) }
                    if result.address >= analysis.imageBase { detail("相对基址", (result.address - analysis.imageBase).hex) }
                }
                if !result.evidence.isEmpty {
                    InspectorSection(title: "匹配依据") {
                        ForEach(Array(result.evidence.enumerated()), id: \.offset) { index, evidence in
                            Label("\(index + 1). \(evidence)", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(ScopeTheme.green)
                        }
                    }
                }
                if let assessment = model.assessment(for: result) {
                    InspectorSection(title: "Codex 评估 · 待验证") {
                        Text(assessment.reason).font(.system(size: 11)).textSelection(.enabled)
                        Text("引用依据：" + assessment.evidenceIndices.map { String($0 + 1) }.joined(separator: "、"))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                if result.kind == .method || result.kind == .classInfo {
                    Button { model.createHookProject(from: result) } label: {
                        Label("为\(result.kind == .method ? "此方法" : "此类")创建 Hook 工程", systemImage: "hammer")
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                    }.buttonStyle(.borderedProminent).font(.system(size: 11))
                }
                payloadContent
                Divider()
                InspectorSection(title: "分析笔记") {
                    TextEditor(text: $note).font(.system(size: 11)).scrollContentBackground(.hidden).frame(minHeight: 90)
                        .padding(8).background(ScopeTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(alignment: .topLeading) {
                            if note.isEmpty { Text("记录这个方法的用途或下一步线索…").font(.system(size: 10)).foregroundStyle(.tertiary).padding(13).allowsHitTesting(false) }
                        }
                    Text("自动保存在本机，重新打开同一路径可恢复。").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }.padding(22)
        }
        .background(ScopeTheme.canvas)
        .onAppear { note = model.note(for: result) }
        .onChange(of: note) { _, value in model.saveNote(value, for: result) }
    }

    private var fileOffset: UInt64? {
        for section in analysis.sections where result.address >= section.address && result.address - section.address < section.size && ![UInt32(1), 0xc, 0x12].contains(section.flags & 0xff) {
            return analysis.sliceOffset + section.fileOffset + result.address - section.address
        }
        return nil
    }

    @ViewBuilder private var payloadContent: some View {
        switch result.payload {
        case .method(let method): methodContent(method)
        case .classInfo(let cls): classContent(cls)
        case .string(let string): stringContent(string)
        case .symbol(let symbol): symbolContent(symbol)
        }
    }

    private func methodContent(_ method: ObjCMethod) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            InspectorSection(title: "接口草稿") {
                code(AnalysisExporter.declaration(method))
                Text("Type encoding: \(method.typeEncoding)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            let strings = analysis.references.filter { $0.function == method.address && $0.kind == .string }
            InspectorSection(title: "引用的字符串（\(strings.count)）") {
                if strings.isEmpty { empty("未找到可解析的字符串引用。") }
                ForEach(Array(strings.prefix(60).enumerated()), id: \.offset) { _, ref in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ref.label).font(.system(size: 11)).textSelection(.enabled)
                        Text("指令 \(ref.instruction.hex)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                truncated(strings.count, limit: 60)
            }
            referenceSection("直接调用此方法", refs: analysis.references.filter { $0.kind == .call && $0.target == method.address })
            InspectorSection(title: "方法内的直接调用") {
                let calls = analysis.references.filter { $0.kind == .call && $0.function == method.address }
                if calls.isEmpty { empty("未找到直接 BL 调用。Objective-C 消息派发通常为间接调用。") }
                ForEach(Array(calls.prefix(40).enumerated()), id: \.offset) { _, ref in functionLink(ref.target, label: ref.label) }
                truncated(calls.count, limit: 40)
            }
            InspectorSection(title: "装载的 Selector") {
                let selectors = Array(Set(analysis.references.filter { $0.function == method.address && $0.kind == .selector }.map(\.label))).sorted()
                if selectors.isEmpty { empty("未找到 Selector 地址装载。") }
                ForEach(selectors.prefix(40), id: \.self) { Text($0).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
                Text("Selector 装载是候选线索，不足以证明具体调用目标。").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private func classContent(_ cls: ObjCClass) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            InspectorSection(title: "类信息") {
                detail("父类", cls.superclass ?? "未解析")
                detail("协议", cls.protocols.isEmpty ? "无已恢复协议" : cls.protocols.joined(separator: ", "))
                detail("属性", "\(cls.properties.count) 个")
            }
            InspectorSection(title: "方法（\(cls.methods.count)）") {
                ForEach(cls.methods.prefix(100)) { method in
                    Button { model.navigateToMethod(address: method.address, imageID: result.imageID) } label: {
                        HStack(alignment: .top) {
                            Text("\(method.isClassMethod ? "+" : "−") \(method.selector)").font(.system(size: 10, design: .monospaced)).multilineTextAlignment(.leading)
                            Spacer(minLength: 2); Image(systemName: "arrow.up.right").font(.system(size: 8))
                        }
                    }.buttonStyle(.plain).foregroundStyle(ScopeTheme.accent)
                }
                truncated(cls.methods.count, limit: 100)
            }
            InspectorSection(title: "接口草稿") {
                Button("复制完整接口草稿") { model.copy(AnalysisExporter.header(cls)) }.font(.system(size: 11))
                code(String(AnalysisExporter.header(cls).prefix(12_000)))
            }
        }
    }

    private func stringContent(_ string: BinaryString) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            InspectorSection(title: "字符串内容") { code(string.value); detail("Section", string.section) }
            referenceSection("引用此字符串的函数", refs: analysis.references.filter { $0.target == string.address && $0.kind != .call })
        }
    }

    private func symbolContent(_ symbol: BinarySymbol) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            InspectorSection(title: "符号信息") {
                let recovered = analysis.symbols.contains { $0.id == symbol.id }
                detail("类型", !recovered ? "未恢复名称的函数" : symbol.isImported ? "外部导入" : symbol.isSwift ? "Swift" : "本地符号")
                code(symbol.rawName)
                if !recovered { Text("sub_ 标签根据静态引用所属函数的地址生成，不是恢复出的原始名称。").font(.system(size: 10)).foregroundStyle(.secondary) }
                if symbol.isSwift { Text("Swift 原生类型与方法主要来自保留的符号；被剥离的名称无法凭空恢复。").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            if !symbol.isImported {
                InspectorSection(title: "函数引用的字符串") {
                    let refs = analysis.references.filter { $0.kind == .string && $0.function == symbol.address }
                    if refs.isEmpty { empty("未发现已支持的静态字符串引用。") }
                    ForEach(Array(refs.prefix(60).enumerated()), id: \.offset) { _, ref in code(ref.label) }
                    truncated(refs.count, limit: 60)
                }
                referenceSection("直接引用此符号的函数", refs: analysis.references.filter { $0.kind == .call && $0.target == symbol.address })
            }
        }
    }

    private func referenceSection(_ title: String, refs: [CodeReference]) -> some View {
        InspectorSection(title: "\(title)（\(refs.count)）") {
            if refs.isEmpty { empty("未发现已支持的静态引用；这不代表运行时没有引用。") }
            ForEach(Array(refs.prefix(60).enumerated()), id: \.offset) { _, ref in
                VStack(alignment: .leading, spacing: 4) {
                    functionLink(ref.function, label: analysis.name(forFunction: ref.function))
                    Text("指令 \(ref.instruction.hex)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
            truncated(refs.count, limit: 60)
        }
    }

    private func functionLink(_ address: UInt64, label: String) -> some View {
        let knownMethod = analysis.classes.contains { $0.methods.contains { $0.address == address } }
        let knownSymbol = analysis.symbols.contains { !$0.isImported && $0.address == address } || analysis.references.contains { $0.function == address }
        return HStack(alignment: .top, spacing: 5) {
            if knownMethod || knownSymbol {
                Button { model.navigateToMethod(address: address, imageID: result.imageID) } label: {
                    Text(label).multilineTextAlignment(.leading)
                }.buttonStyle(.plain).foregroundStyle(ScopeTheme.accent)
            } else {
                Text(label).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button { model.copy(address.hex) } label: { Image(systemName: "doc.on.doc").font(.system(size: 9)) }.buttonStyle(.borderless).help("复制函数地址")
        }.font(.system(size: 10, design: .monospaced))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).fontDesign(.monospaced).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 10))
    }
    private func code(_ text: String) -> some View {
        Text(text).font(.system(size: 10, design: .monospaced)).lineSpacing(4).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(ScopeTheme.panel, in: RoundedRectangle(cornerRadius: 8))
    }
    private func empty(_ text: String) -> some View { Text(text).font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3) }
    @ViewBuilder private func truncated(_ count: Int, limit: Int) -> some View {
        if count > limit { Text("显示前 \(limit) 条，完整内容可通过 JSON 导出。").font(.system(size: 9)).foregroundStyle(.tertiary) }
    }
}

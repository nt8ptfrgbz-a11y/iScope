import SwiftUI
import AppKit
import iScopeCore

struct FeatureSearchTabs: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button("关键词结果", action: model.useKeywordSearch)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(!model.isSmartMode ? ScopeTheme.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                ForEach(model.featureSearchSessions) { session in
                    HStack(spacing: 7) {
                        Button { model.restoreFeatureSearch(session.id) } label: {
                            Label(session.query, systemImage: "scope").lineLimit(1).frame(maxWidth: 190)
                        }.help("返回定位结果 · " + session.scopeTitle)
                        Button { model.closeFeatureSearch(session.id) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).padding(3).contentShape(Rectangle())
                        }.help("关闭这次定位结果").accessibilityLabel("关闭定位结果：" + session.query)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(model.isSmartMode && model.selectedFeatureSearchID == session.id ? ScopeTheme.accent.opacity(0.12) : ScopeTheme.panel,
                                in: RoundedRectangle(cornerRadius: 7))
                }
            }.buttonStyle(.plain).font(.system(size: 11)).padding(.horizontal, 16).padding(.vertical, 9)
        }.scrollIndicators(.hidden)
        .background(.bar)
    }
}

struct SmartSearchPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if model.isSmartSearching { ProgressView().controlSize(.mini) }
                else { Image(systemName: "sparkle.magnifyingglass").foregroundStyle(ScopeTheme.accent) }
                Text(model.smartStatus).font(.system(size: 11, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
                if model.isSmartSearching { Button("取消", action: model.cancelSmartSearch).buttonStyle(.link) }
                Button("关键词结果", action: model.useKeywordSearch).buttonStyle(.link)
            }.font(.system(size: 10))
            if let session = model.activeFeatureSearch {
                Text("结果已保留 · " + session.scopeTitle + " · 关闭标签前可随时返回")
                    .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error = model.smartError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                Button("Codex 设置…") { model.showCodexSettings = true }.font(.system(size: 10))
            }
            if let plan = model.smartPlan {
                Text(plan.summary).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                Text("应用背景：\(plan.appContext.isEmpty ? "未指定" : plan.appContext)   ·   动作：\(plan.action)")
                    .font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                DisclosureGroup("检索计划与范围") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(plan.concepts.enumerated()), id: \.offset) { _, concept in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(role(concept.role)) · \(concept.label)").fontWeight(.medium)
                                    Text(concept.terms.joined(separator: " · ")).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                            ForEach(plan.cautions, id: \.self) { Text($0).foregroundStyle(.secondary) }
                            ForEach(model.smartResponse?.notes ?? [], id: \.self) { Text($0).foregroundStyle(.secondary) }
                            if let summary = model.smartReview?.summary { Text("Codex 评估（待验证）：" + summary).foregroundStyle(.secondary) }
                            Button("复制计划 JSON") {
                                if let data = try? JSONEncoder().encode(plan) { model.copy(String(decoding: data, as: UTF8.self)) }
                            }.buttonStyle(.link)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }.frame(maxHeight: 200)
                }.font(.system(size: 10))
            }
            if let error = model.reviewError { Text(error + " 已保留本地候选。").font(.system(size: 10)).foregroundStyle(.orange) }
            if let clues = model.smartResponse?.clues, !clues.isEmpty {
                DisclosureGroup("文本线索（\(clues.count)）") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(clues) { clue in
                            Button { model.navigateToClue(clue) } label: {
                                Text("\(clue.imageName) · \(clue.title)").lineLimit(1).truncationMode(.middle)
                            }.buttonStyle(.link)
                        }
                    }.padding(.top, 6)
                }.font(.system(size: 10))
            }
        }.padding(14).background(ScopeTheme.accent.opacity(0.045))
    }

    private func role(_ role: FeatureConcept.Role) -> String {
        switch role { case .feature: return "核心功能"; case .action: return "明确动作"; case .context: return "背景"; case .hint: return "辅助猜测" }
    }
}

struct CodexSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Codex 智能定位", systemImage: "sparkle.magnifyingglass").font(.system(size: 21, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("复用本机 Codex CLI 的模型服务、登录或自定义 Provider。iScope 不读取密钥，也不修改 Codex 的全局配置。")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            Form {
                LabeledContent("CLI 路径") {
                    HStack {
                        TextField(CodexCLI.discoverExecutable() ?? "自动检测 codex", text: $model.codexSettings.executablePath)
                        Button("选择…", action: chooseExecutable)
                    }
                }
                TextField("模型（可选）", text: $model.codexSettings.model, prompt: Text("留空使用 Codex 配置"))
                TextField("Profile（可选）", text: $model.codexSettings.profile, prompt: Text("留空使用默认配置"))
                Stepper("单次超时：\(Int(model.codexSettings.timeout)) 秒", value: $model.codexSettings.timeout, in: 30...600, step: 30)
                Toggle("本地检索后，让 Codex 评估前 20 个候选", isOn: $model.codexSettings.reviewCandidates)
            }.formStyle(.grouped)
            HStack {
                Button("检查 CLI", action: model.checkCodex).disabled(model.isCheckingCodex)
                if model.isCheckingCodex { ProgressView().controlSize(.small) }
                Text(model.codexStatus).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("什么时候调用？").font(.system(size: 12, weight: .semibold))
                Text("点击“智能定位”才会发起请求。第一步只发送功能描述；开启候选评估后，再发送最多 20 条候选的名称、文件名和匹配证据摘要。IPA、二进制和完整索引不作为请求输入。")
                Text("请求交给你配置的模型服务处理；本机 CLI 不代表本地模型。检索在本地执行，模型判断仍需用实际行为验证。")
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }.padding(26).frame(width: 650)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex CLI 可执行文件"; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.showsHiddenFiles = true
        if let path = CodexCLI.discoverExecutable() { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { model.codexSettings.executablePath = url.path }
    }
}

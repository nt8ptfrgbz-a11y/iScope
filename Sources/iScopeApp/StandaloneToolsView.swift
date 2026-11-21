import SwiftUI
import iScopeCore

struct StandaloneToolsView: View {
    @ObservedObject var model: WorkflowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("独立操作").font(.headline)
            Text("点击按钮选择文件，即可单独执行这一步。").font(.caption).foregroundStyle(.secondary)
            tool("1", "编译 Hook → dylib", "选择 .m / .mm，dylib 输出到源码同目录。", icon: "hammer", action: model.chooseSourceAndBuild)
            tool("2", "注入 dylib → 未签名 IPA", "选择 dylib 目录，默认查找同目录的 IPA。", icon: "shippingbox", action: model.chooseDylibDirectory)
            tool("3", "重新签名 IPA", "选择 IPA，签名产物输出到 IPA 同目录。", icon: "signature") { model.chooseIPAAndRun(.signExisting) }
            tool("4", "安装 IPA 到设备", "选择已签名 IPA，安装到下方所选真机。", icon: "iphone.and.arrow.forward") { model.chooseIPAAndRun(.installExisting) }
            Text("输出重名时自动编号；可在右侧查看日志和显示产物。").font(.caption2).foregroundStyle(.secondary)
        }.disabled(model.isRunning || model.isProbing)
    }

    private func tool(_ number: String, _ title: String, _ detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(number).font(.caption.bold()).foregroundStyle(ScopeTheme.accent)
                    .frame(width: 23, height: 23).background(ScopeTheme.accent.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(ScopeTheme.panel, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

struct DylibPackageSelectionView: View {
    @ObservedObject var model: WorkflowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("注入 dylib", systemImage: "shippingbox").font(.title3.bold())
            Text(model.dylibDirectory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("选择要注入的动态库").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.availableDylibs, id: \.path) { url in
                        Toggle(url.lastPathComponent, isOn: Binding(
                            get: { model.selectedDylibs.contains(url.path) },
                            set: { if $0 { model.selectedDylibs.insert(url.path) } else { model.selectedDylibs.remove(url.path) } }
                        ))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
            Text("原始 IPA").font(.headline)
            if !model.availableIPAs.isEmpty {
                Picker("同目录 IPA", selection: $model.packageIPA) {
                    Text("请选择原始 IPA").tag("")
                    ForEach(model.availableIPAs, id: \.path) { Text($0.lastPathComponent).tag($0.path) }
                    if !model.packageIPA.isEmpty && !model.availableIPAs.contains(where: { $0.path == model.packageIPA }) {
                        Text("已选择其他目录的 IPA").tag(model.packageIPA)
                    }
                }
            }
            HStack {
                Text(model.packageIPA.isEmpty ? "同目录未找到唯一 IPA，请选择文件。" : model.packageIPA)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button("另选 IPA…", action: model.choosePackageIPA)
            }
            Text("未签名 IPA 输出到 dylib 所在目录。多个 dylib 可一起注入；目录包含不同构建版本时，请选择需要的版本。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { model.showPackageSelection = false }.keyboardShortcut(.cancelAction)
                Button("生成未签名 IPA", action: model.packageSelectedDylibs).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(model.selectedDylibs.isEmpty || model.packageIPA.isEmpty)
            }
        }.padding(24).frame(width: 560)
    }
}

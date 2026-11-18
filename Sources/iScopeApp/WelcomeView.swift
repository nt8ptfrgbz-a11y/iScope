import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 28)
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 26).fill(LinearGradient(colors: [ScopeTheme.accent, Color(red: 0.32, green: 0.25, blue: 0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            Image(systemName: "scope").font(.system(size: 53, weight: .light)).foregroundStyle(.white)
                        }.frame(width: 104, height: 104).shadow(color: ScopeTheme.accent.opacity(0.18), radius: 18, y: 9)
                        Text("iScope").font(.system(size: 36, weight: .bold, design: .rounded))
                        Text("从一个功能，找到它的方法。").font(.system(size: 20, weight: .medium))
                        Text("探索 iOS 应用的类、方法与字符串，让每一条线索都有迹可循。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    VStack(spacing: 14) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 28, weight: .light)).foregroundStyle(ScopeTheme.accent)
                        Text("将脱壳 IPA 或 Mach-O 拖到这里").font(.system(size: 14, weight: .medium))
                        Text("也支持 .app、Framework 和 dylib").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button(action: model.openPanel) { Label("选择文件", systemImage: "folder").padding(.horizontal, 12).padding(.vertical, 3) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    .frame(maxWidth: .infinity).padding(28)
                    .background(ScopeTheme.accent.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ScopeTheme.accent.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6])))

                    HStack(alignment: .top, spacing: 24) {
                        feature("scope", "按功能定位", "中文关键词扩展\n字符串引用追踪")
                        feature("square.stack.3d.up", "还原应用结构", "类、Category 与协议\nSwift 符号还原")
                        feature("square.and.arrow.up", "带走分析线索", "类名、方法名与接口\nCSV / JSON 导出")
                    }.padding(.vertical, 2)
                    if !model.recentPaths.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("最近打开").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            ForEach(model.recentPaths, id: \.self) { path in
                                Button { model.open(URL(fileURLWithPath: path)) } label: {
                                    HStack {
                                        Image(systemName: "doc.zipper").foregroundStyle(.secondary)
                                        Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                                        Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                                    }.font(.system(size: 11)).padding(7).contentShape(Rectangle())
                                }.buttonStyle(.plain).help(path)
                            }
                        }
                    }
                    Spacer(minLength: 28)
                }
                .frame(width: 580).frame(maxWidth: .infinity).frame(minHeight: geometry.size.height)
            }
        }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(ScopeTheme.accent)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

import SwiftUI
import AppKit
import iScopeCore

@main
struct IScopeApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            WorkspaceView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 700)
                .onOpenURL { model.open($0) }
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入 IPA / Mach-O…", action: model.openPanel).keyboardShortcut("o")
                Button("导出分析结果…") { model.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.analyses.isEmpty)
            }
            CommandMenu("分析") {
                Button("Codex 智能定位", action: model.startSmartSearch).keyboardShortcut(.return, modifiers: [.command]).disabled(!model.canSmartSearch)
                Button("Codex 设置…") { model.showCodexSettings = true }
                Button("Hook 编译与部署…") { model.showWorkflow = true }.keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("功能定位") { model.page = .all }.keyboardShortcut("1")
                Button("浏览方法") { model.page = .methods }.keyboardShortcut("2")
                Button("浏览字符串") { model.page = .strings }.keyboardShortcut("3")
                Divider()
                Button("创建 Xcode Hook 工程…") { model.createHookProject() }.keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(!model.orderedAnalyses.contains { !$0.methods.isEmpty })
                Button("分析全部 Mach-O", action: model.analyzeAll).disabled(!model.canAnalyzeAll)
                Button("取消分析", action: model.cancelWork).disabled(!model.isWorking)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        WorkflowEngine.stopAll()
        for url in TemporaryArtifacts.directories { try? FileManager.default.removeItem(at: url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

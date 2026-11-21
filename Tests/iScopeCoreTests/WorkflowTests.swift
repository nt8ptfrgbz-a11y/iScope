import XCTest
@testable import iScopeCore

final class WorkflowTests: XCTestCase {
    func testWorkflowCancellationWaitsForCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iScope-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready"), cleaned = directory.appendingPathComponent("cleaned")
        let script = directory.appendingPathComponent("cancel.py")
        try """
        import os,signal,time,sys
        from pathlib import Path
        os.setpgrp()
        def cancel(signum, frame):
            time.sleep(0.2)
            Path(sys.argv[2]).write_text('cleaned')
            sys.exit(130)
        signal.signal(signal.SIGTERM, cancel)
        Path(sys.argv[1]).write_text('ready')
        while True: time.sleep(1)
        """.write(to: script, atomically: true, encoding: .utf8)
        let python = try WorkflowEngine.pythonExecutable()
        let worker = Task.detached { try ProcessRunner.run(python, ["-B", script.path, ready.path, cleaned.path], workflow: true) }
        defer { worker.cancel() }
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        worker.cancel()
        do { _ = try await worker.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path), "Workflow must finish graceful cleanup before returning")
    }

    func testEventFramingAcrossUTF8Boundaries() throws {
        let decoder = WorkflowEventDecoder()
        let data = Data("{\"version\":1,\"type\":\"log\",\"message\":\"编译中文路径\"}\n{\"version\":1,\"type\":\"stage\",\"stage\":\"build\",\"state\":\"done\"}\n".utf8)
        var events: [WorkflowEvent] = []
        for byte in data { try decoder.append(Data([byte])) { events.append($0) } }
        try decoder.finish()
        XCTAssertEqual(events.map(\.type), ["log", "stage"])
        XCTAssertEqual(events.first?.message, "编译中文路径")
        XCTAssertEqual(events.last?.state, "done")
        XCTAssertThrowsError(try decoder.append(Data("{\"version\":2,\"type\":\"log\"}\n".utf8)) { _ in })
    }

    func testSavedConfigurationWithoutStandaloneFieldsStillDecodes() throws {
        var original = WorkflowRequest()
        original.projectPath = "/tmp/Existing.xcodeproj"
        original.bundleIdentifier = "com.example.saved"
        let saved = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(WorkflowRequest.self, from: saved)
        XCTAssertEqual(restored.projectPath, original.projectPath)
        XCTAssertEqual(restored.bundleIdentifier, original.bundleIdentifier)
        XCTAssertNil(restored.sourcePath)
        XCTAssertNil(restored.dylibPaths)
        XCTAssertNil(restored.architectures)
    }

    private func executeStandalone(_ request: WorkflowRequest, completed: [String]) async throws -> WorkflowResult {
        var result: WorkflowResult?
        var stages: [String] = []
        var logs = ""
        do {
            for try await event in WorkflowEngine.events(for: request) {
                if let value = event.result { result = value }
                if event.type == "stage", event.state == "done", let stage = event.stage { stages.append(stage) }
                if let message = event.message { logs += message + "\n" }
            }
        } catch { throw ScopeError.tool(error.localizedDescription + "\n" + logs.suffix(12000)) }
        XCTAssertEqual(stages, completed)
        return try XCTUnwrap(result)
    }

    func testRealBuildInjectionAndOptionalSigning() async throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("iScope pipeline 中文 \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Input/Payload/Counter.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let bundleID = "com.example.iscope.workflowtest"
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "Main", "CFBundleName": "Counter",
                                   "CFBundleDisplayName": "计数测试", "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                                   "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "15.0", "CFBundleSupportedPlatforms": ["iPhoneOS"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let main = directory.appendingPathComponent("Main.m")
        try """
        #import <Foundation/Foundation.h>
        @interface SampleCounter : NSObject
        - (NSInteger)steps;
        @end
        @implementation SampleCounter
        - (NSInteger)steps { return 42; }
        @end
        int main(void) { @autoreleasepool { NSLog(@"%ld", (long)[[SampleCounter new] steps]); } return 0; }
        """.write(to: main, atomically: true, encoding: .utf8)
        let sdk = try ProcessRunner.run("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try ProcessRunner.run("/usr/bin/xcrun", ["--sdk", "iphoneos", "clang", "-arch", "arm64", "-isysroot", sdk,
                                                    "-miphoneos-version-min=15.0", "-fobjc-arc", "-framework", "Foundation",
                                                    "-Wl,-headerpad,0x4000", main.path, "-o", app.appendingPathComponent("Main").path])
        let ipa = directory.appendingPathComponent("原始 IPA.ipa")
        _ = try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--keepParent", app.deletingLastPathComponent().path, ipa.path])
        let original = try Data(contentsOf: ipa)
        let method = ObjCMethod(className: "SampleCounter", selector: "steps", typeEncoding: "q16@0:8", address: 0, fileOffset: 0, isClassMethod: false)
        let project = try HookProjectGenerator.write(.init(name: "CounterHook", bundleIdentifier: bundleID, methods: [method]), to: directory)
        let source = try Data(contentsOf: project.appendingPathComponent("Hooks.m"))
        let signing = ProcessInfo.processInfo.environment["ISCOPE_LIVE_SIGNING"] == "1"
        var request = WorkflowRequest()
        request.target = signing ? .sign : .package
        request.projectPath = project.appendingPathComponent("CounterHook.xcodeproj").path
        request.inputPath = ipa.path
        request.outputDirectory = project.appendingPathComponent("iScopeOutput").path
        let legacy = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/ios-hook-tools")
        request.profileSearchDirectories = [legacy.path, legacy.appendingPathComponent("profiles").path]
        var result: WorkflowResult?
        var completed: [String] = []
        var log = ""
        do {
            for try await event in WorkflowEngine.events(for: request) {
                if let value = event.result { result = value }
                if event.type == "stage", event.state == "done", let stage = event.stage { completed.append(stage) }
                if event.type == "log", let message = event.message { log += message + "\n" }
            }
        } catch { return XCTFail("Workflow failed: \(error.localizedDescription)\n\(log.suffix(12000))") }
        let output = try XCTUnwrap(result)
        XCTAssertEqual(completed, signing ? ["preflight", "build", "package", "sign"] : ["preflight", "build", "package"])
        XCTAssertEqual(try Data(contentsOf: ipa), original)
        XCTAssertEqual(try Data(contentsOf: project.appendingPathComponent("Hooks.m")), source)
        XCTAssertFalse(output.installed)
        XCTAssertEqual(output.signatureVerified, signing)
        let product = try XCTUnwrap(signing ? output.signedIPA : output.unsignedIPA)
        let extracted = directory.appendingPathComponent("Verified")
        _ = try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", product, extracted.path])
        let restored = extracted.appendingPathComponent("Payload/Counter.app")
        let dependencies = try ProcessRunner.run("/usr/bin/otool", ["-L", restored.appendingPathComponent("Main").path])
        XCTAssertTrue(dependencies.contains("@executable_path/Frameworks/CounterHook.dylib"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("Frameworks/CounterHook.dylib").path))
        if signing {
            _ = try ProcessRunner.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", restored.path])
            XCTAssertEqual(output.bundleIdentifier, bundleID + ".regisn")
            let snapshot = URL(fileURLWithPath: output.runDirectory).appendingPathComponent("SourceSnapshot/Hooks.m")
            XCTAssertTrue(try String(contentsOf: snapshot, encoding: .utf8).contains(bundleID + ".regisn"))
        }

        // Exercise the same JSON-lines entry point used by the four independent buttons.
        let standalone = directory.appendingPathComponent("独立工具 输出")
        try FileManager.default.createDirectory(at: standalone, withIntermediateDirectories: true)
        let hook = standalone.appendingPathComponent("自定义 Hook.m")
        try source.write(to: hook)
        var build = WorkflowRequest()
        build.target = .buildSource; build.sourcePath = hook.path
        build.architectures = ["arm64", "arm64e"]
        build.outputDirectory = standalone.path
        let built = try await executeStandalone(build, completed: ["preflight", "build"])
        let dylib = try XCTUnwrap(built.dylib)
        XCTAssertEqual(URL(fileURLWithPath: dylib).resolvingSymlinksInPath().path, hook.deletingPathExtension().appendingPathExtension("dylib").resolvingSymlinksInPath().path)
        XCTAssertEqual(try Data(contentsOf: hook), source)
        let library = try Data(contentsOf: URL(fileURLWithPath: dylib))
        let rebuilt = try await executeStandalone(build, completed: ["preflight", "build"])
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(rebuilt.dylib)).resolvingSymlinksInPath().path,
                       standalone.appendingPathComponent("自定义 Hook-2.dylib").resolvingSymlinksInPath().path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dylib)), library)
        var inject = WorkflowRequest()
        inject.target = .packageExisting; inject.inputPath = ipa.path
        inject.dylibPaths = [dylib]; inject.outputDirectory = standalone.path
        let injected = try await executeStandalone(inject, completed: ["preflight", "package"])
        let unsigned = try XCTUnwrap(injected.unsignedIPA)
        XCTAssertEqual(URL(fileURLWithPath: unsigned).deletingLastPathComponent().resolvingSymlinksInPath().path, standalone.resolvingSymlinksInPath().path)
        XCTAssertFalse(injected.signatureVerified)
        let standaloneExtracted = directory.appendingPathComponent("StandaloneVerified")
        _ = try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", unsigned, standaloneExtracted.path])
        let injectedLibrary = standaloneExtracted.appendingPathComponent("Payload/Counter.app/Frameworks/自定义 Hook.dylib")
        XCTAssertEqual(try Data(contentsOf: injectedLibrary), library)
        let injectedLoads = try ProcessRunner.run("/usr/bin/otool", ["-L", standaloneExtracted.appendingPathComponent("Payload/Counter.app/Main").path])
        XCTAssertTrue(injectedLoads.contains("@executable_path/Frameworks/自定义 Hook.dylib"))
        XCTAssertEqual(try Data(contentsOf: ipa), original)
        if signing {
            var resign = WorkflowRequest()
            resign.target = .signExisting; resign.inputPath = unsigned
            resign.outputDirectory = standalone.path
            resign.profileSearchDirectories = request.profileSearchDirectories
            let resigned = try await executeStandalone(resign, completed: ["preflight", "sign"])
            XCTAssertTrue(resigned.signatureVerified)
            XCTAssertFalse(resigned.installed)
            XCTAssertNil(resigned.dylib)
            XCTAssertNil(resigned.unsignedIPA)
            XCTAssertEqual(resigned.bundleIdentifier, bundleID + ".regisn")
            XCTAssertEqual(resigned.signedIPA, URL(fileURLWithPath: unsigned).deletingPathExtension().path + "-resign.ipa")
        }
    }
}

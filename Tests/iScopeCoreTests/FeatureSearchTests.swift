import XCTest
@testable import iScopeCore

final class FeatureSearchTests: XCTestCase {
    private var plan: FeatureSearchPlan {
        FeatureSearchPlan(summary: "定位微信运动中与步数相关的实现；动作尚未指定。", appContext: "微信", action: "未指定",
                          concepts: [FeatureConcept(label: "步数", role: .feature, terms: ["stepCount", "numberOfSteps", "pedometer", "步数", "step"]),
                                     FeatureConcept(label: "应用背景", role: .context, terms: ["WeChat", "微信"]),
                                     FeatureConcept(label: "可能的系统 API", role: .hint, terms: ["CMPedometer", "CoreMotion"])],
                          cautions: ["检索词不是已验证的方法名。"])
    }

    private func fixture(noiseCount: Int = 2200) -> BinaryAnalysis {
        func method(_ cls: String, _ name: String, _ address: UInt64) -> ObjCMethod {
            ObjCMethod(className: cls, selector: name, typeEncoding: "v16@0:8", address: address, fileOffset: nil, isClassMethod: false)
        }
        let name = "ExerciseStepManager"
        let methods = [method(name, "uploadStepCount:", 0x1000), method(name, "numberOfSteps", 0x1010),
                       method(name, "viewDidLoad", 0x1020), method(name, "opaqueImplementation", 0x1030),
                       method(name, "refreshTimeline", 0x1050)]
        let noise = (0..<noiseCount).map { method("Workflow", "nextStepWithState\($0):", UInt64(0x10000 + $0 * 16)) }
        let classes = [ObjCClass(name: name, superclass: "NSObject", address: 0x2000, methods: methods, properties: [], protocols: [], isCategory: false),
                       ObjCClass(name: "Workflow", superclass: "NSObject", address: 0x3000, methods: noise, properties: [], protocols: [], isCategory: false)]
        let refs = [CodeReference(instruction: 0x1004, target: 0x5000, function: 0x1000, kind: .string, label: "/api/exercise/step_count"),
                    CodeReference(instruction: 0x1034, target: 0x5010, function: 0x1030, kind: .string, label: "今日步数"),
                    CodeReference(instruction: 0x1044, target: 0x5020, function: 0x1040, kind: .string, label: "微信运动步数"),
                    CodeReference(instruction: 0x1054, target: 0x1030, function: 0x1050, kind: .call, label: "opaqueImplementation")]
        let image = BinaryImage(url: URL(fileURLWithPath: "/tmp/MyApp"), relativePath: "MyApp", size: 1, architectures: ["arm64"], isMainExecutable: true)
        return BinaryAnalysis(image: image, architecture: "arm64", uuid: nil, encrypted: false, imageBase: 0, sliceOffset: 0, sections: [], classes: classes,
                              symbols: [BinarySymbol(rawName: "_CMPedometer", name: "CMPedometer", address: 0, isImported: true, isSwift: false)],
                              strings: [BinaryString(value: "微信运动步数", address: 0x5020, section: "__cfstring")], references: refs,
                              dependencies: [], warnings: [], elapsed: 0)
    }

    func testDistinctiveEvidenceOutranksThousandsOfGenericStepMethods() throws {
        let response = try FeatureSearchEngine.search([fixture()], plan: plan)
        XCTAssertEqual(response.results.count, 20)
        XCTAssertGreaterThan(response.total, 2000)
        XCTAssertEqual(response.results.first?.address, 0x1000)
        XCTAssertTrue(response.results.prefix(5).contains { $0.address == 0x1010 })
        XCTAssertTrue(response.results.prefix(5).contains { $0.address == 0x1030 })
        XCTAssertFalse(response.results.prefix(5).contains { $0.address == 0x1020 })
        let method = try XCTUnwrap(response.results.first { $0.address == 0x1000 })
        XCTAssertTrue(method.evidence.contains { $0.contains("直接引用字符串") && $0.contains("/api/exercise/step_count") })
        XCTAssertTrue(response.results.contains { $0.address == 0x1040 && $0.title == "sub_1040" })
        XCTAssertFalse(response.results.contains { $0.address == 0 })
        XCTAssertEqual(response.clues.first?.title, "微信运动步数")
    }

    func testHintsAndAppContextAloneCannotCreateCandidates() throws {
        let hintOnly = FeatureSearchPlan(summary: "完全不同的功能", appContext: "Workflow", action: "未指定",
                                        concepts: [FeatureConcept(label: "核心", role: .feature, terms: ["unmatchedFeature"]),
                                                   FeatureConcept(label: "背景", role: .context, terms: ["Workflow"]),
                                                   FeatureConcept(label: "提示", role: .hint, terms: ["step"])], cautions: [])
        let response = try FeatureSearchEngine.search([fixture()], plan: hintOnly)
        XCTAssertEqual(response.total, 0)
        XCTAssertTrue(response.results.isEmpty)
    }

    func testOneHopAndUnrecoveredFunctionKeepActualEvidence() throws {
        let response = try FeatureSearchEngine.search([fixture(noiseCount: 0)], plan: plan)
        let caller = try XCTUnwrap(response.results.first { $0.address == 0x1050 })
        XCTAssertTrue(caller.evidence.contains { $0.contains("一层 BL") && $0.contains("今日步数") })
        XCTAssertLessThan(caller.score, try XCTUnwrap(response.results.first { $0.address == 0x1030 }).score)
        XCTAssertTrue(try XCTUnwrap(response.results.first { $0.address == 0x1040 }).subtitle.contains("未恢复名称"))
        let unknown = try XCTUnwrap(response.results.first { $0.address == 0x1040 })
        let bookmarked = try SearchEngine.search([fixture(noiseCount: 0)], query: "", bookmarked: [unknown.id])
        XCTAssertEqual(bookmarked.results.map(\.id), [unknown.id])
        let navigation = try SearchEngine.search([fixture(noiseCount: 0)], query: "0x1040", kind: .symbol)
        XCTAssertEqual(navigation.results.first?.id, unknown.id)
    }

    func testPlansAndCandidateReviewsRejectUnsupportedClaims() throws {
        let invalid = FeatureSearchPlan(summary: "test", appContext: "", action: "未指定", concepts: [FeatureConcept(label: "提示", role: .hint, terms: ["HealthKit"])], cautions: [])
        XCTAssertThrowsError(try invalid.validated())
        let results = Array(try FeatureSearchEngine.search([fixture(noiseCount: 0)], plan: plan).results.prefix(1))
        let result = try XCTUnwrap(results.first)
        let valid = CandidateReview(summary: "候选", assessments: [.init(id: result.id, relevance: .likely, reason: "名称含步数关键词", evidenceIndices: [0])])
        XCTAssertNoThrow(try valid.validated(for: results))
        XCTAssertThrowsError(try CandidateReview(summary: "未知", assessments: [.init(id: "invented", relevance: .likely, reason: "猜测", evidenceIndices: [0])]).validated(for: results))
        XCTAssertThrowsError(try CandidateReview(summary: "越界", assessments: [.init(id: result.id, relevance: .likely, reason: "猜测", evidenceIndices: [999])]).validated(for: results))
    }

    func testCLIUsesStdinStructuredOutputAndTemporaryWorkspace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("codex")
        let data = try JSONEncoder().encode(plan)
        try data.write(to: executable.appendingPathExtension("json"))
        let script = """
        #!/usr/bin/python3
        import json,sys,pathlib
        if '--version' in sys.argv:
            print('codex-cli test');sys.exit(0)
        if 'mcp' in sys.argv:
            assert sys.argv[1:3] == ['--profile','iscope-test']
            print(json.dumps([{'name':'iscope_trap','enabled':True}]));sys.exit(0)
        args=sys.argv
        assert '--ephemeral' in args and 'read-only' in args
        assert 'features.shell_tool=false' in args and 'mcp_servers={}' in args
        assert 'mcp_servers.iscope_trap.enabled=false' in args
        assert args[args.index('--profile')+1] == 'iscope-test'
        schema=json.loads(pathlib.Path(args[args.index('--output-schema')+1]).read_text())
        assert schema['additionalProperties'] == False
        text=sys.stdin.read()
        assert 'INPUT JSON:' in text and '微信运动步数' in text
        assert args[-1] == '-'
        response=pathlib.Path(__file__+'.json').read_text()
        pathlib.Path(args[args.index('--output-last-message')+1]).write_text(response)
        pathlib.Path(__file__+'.workspace').write_text(args[args.index('--cd')+1])
        print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':response}}))
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var settings = CodexSettings(); settings.executablePath = executable.path; settings.profile = "iscope-test"
        XCTAssertEqual(try CodexCLI.check(settings), "codex-cli test")
        let parsed = try CodexCLI.makePlan(description: "微信运动步数 $(touch /tmp/never-execute)", settings: settings)
        XCTAssertEqual(parsed, plan)
        let temporaryWorkspace = try String(contentsOf: executable.appendingPathExtension("workspace"), encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryWorkspace))
        let toolScript = script.replacingOccurrences(of: "'type':'agent_message'", with: "'type':'command_execution'")
        try toolScript.write(to: executable, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CodexCLI.makePlan(description: "微信运动步数", settings: settings))
    }

    func testProcessDrainsPipesEnforcesLimitsAndTimeout() throws {
        let output = try ProcessRunner.run("/usr/bin/python3", ["-c", "import sys;sys.stderr.write('e'*300000);sys.stdout.write('o'*300000);print(len(sys.stdin.buffer.read()))"], input: Data(repeating: 65, count: 1_000_000), timeout: 10, maxOutputBytes: 2_000_000)
        XCTAssertTrue(output.hasSuffix("1000000\n"))
        XCTAssertEqual(output.filter { $0 == "o" }.count, 300_000)
        XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/python3", ["-c", "print('x'*20000)"], maxOutputBytes: 1024))
        let start = Date()
        XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/python3", ["-c", "import time;time.sleep(10)"], timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testProcessCancellationStopsTheRequest() async throws {
        let task = Task.detached { try ProcessRunner.run("/usr/bin/python3", ["-c", "import time;time.sleep(10)"], timeout: 20) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }

    /// Opt-in: only a synthetic description and this test's fixture evidence are sent to the configured service.
    func testLiveCodexPlanAndCandidateReview() throws {
        guard ProcessInfo.processInfo.environment["ISCOPE_LIVE_CODEX"] == "1" else { throw XCTSkip("Set ISCOPE_LIVE_CODEX=1 to exercise your configured Codex service.") }
        let settings = CodexSettings()
        let actual = try CodexCLI.makePlan(description: "微信运动步数", settings: settings)
        XCTAssertTrue(actual.action.contains("未指定"))
        XCTAssertTrue(actual.concepts.contains { $0.role == .feature })
        print("Live Codex plan:", String(decoding: try JSONEncoder().encode(actual), as: UTF8.self))
        let candidates = try FeatureSearchEngine.search([fixture(noiseCount: 0)], plan: actual).results
        XCTAssertFalse(candidates.isEmpty)
        let review = try CodexCLI.review(plan: actual, candidates: candidates, settings: settings)
        XCTAssertEqual(review.assessments.count, candidates.count)
        print("Live Codex review: validated \(review.assessments.count) fixture candidates.")
    }
}

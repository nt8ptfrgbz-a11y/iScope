import XCTest
@testable import iScopeApp
@testable import iScopeCore

final class AppModelTests: XCTestCase {
    @MainActor func testStandaloneDirectorySelectionAndRequestsDoNotRequireProject() throws {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("iScope-tools 中文 \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = WorkflowModel()
        XCTAssertTrue(model.standaloneMode)
        XCTAssertThrowsError(try model.preparePackage(directory: directory))
        let dylib = directory.appendingPathComponent("Hook.dylib")
        let ipa = directory.appendingPathComponent("Original.ipa")
        try Data([1]).write(to: dylib); try Data([2]).write(to: ipa)
        // A directory named like a dylib is not a selectable library.
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Folder.dylib"), withIntermediateDirectories: false)
        try model.preparePackage(directory: directory)
        XCTAssertEqual(model.availableDylibs.map { $0.resolvingSymlinksInPath().path }, [dylib.resolvingSymlinksInPath().path])
        XCTAssertEqual(model.selectedDylibs, Set(model.availableDylibs.map(\.path)))
        XCTAssertEqual(URL(fileURLWithPath: model.packageIPA).resolvingSymlinksInPath().path, ipa.resolvingSymlinksInPath().path)
        XCTAssertTrue(model.showPackageSelection)
        let other = directory.appendingPathComponent("Hook-2.dylib")
        try Data([3]).write(to: other)
        try Data([4]).write(to: directory.appendingPathComponent("Original-unsigned.ipa"))
        try model.preparePackage(directory: directory)
        XCTAssertTrue(model.selectedDylibs.isEmpty, "Different build versions require a deliberate selection")
        XCTAssertTrue(model.packageIPA.isEmpty, "Do not guess which IPA is original when several exist")
        let selected = try XCTUnwrap(model.availableDylibs.first { $0.lastPathComponent == other.lastPathComponent })
        model.selectedDylibs = [selected.path]
        let externalIPA = directory.appendingPathComponent("Other Directory/App.ipa")
        let injection = model.standaloneRequest(.packageExisting, input: externalIPA)
        XCTAssertEqual(injection.projectPath, "")
        XCTAssertEqual(injection.inputPath, externalIPA.path)
        XCTAssertEqual(injection.outputDirectory, directory.path)
        XCTAssertEqual(injection.dylibPaths, [selected.path])
        let hook = directory.appendingPathComponent("Hook.m")
        let build = model.standaloneRequest(.buildSource, input: hook)
        XCTAssertEqual(build.sourcePath, hook.path)
        XCTAssertEqual(build.inputPath, "")
        XCTAssertEqual(build.outputDirectory, directory.path)
        XCTAssertEqual(build.architectures, ["arm64"])
        let sign = model.standaloneRequest(.signExisting, input: externalIPA)
        XCTAssertEqual(sign.outputDirectory, externalIPA.deletingLastPathComponent().path)
        XCTAssertNil(sign.sourcePath); XCTAssertNil(sign.dylibPaths)
        let install = model.standaloneRequest(.installExisting, input: externalIPA)
        XCTAssertEqual(install.inputPath, externalIPA.path)
        XCTAssertEqual(install.outputDirectory, externalIPA.deletingLastPathComponent().path)
        XCTAssertEqual(install.projectPath, "")
    }

    private struct Fixture {
        let model: AppModel
        let directory: URL
        let image: BinaryImage
        let analysis: BinaryAnalysis
        let invocationFile: URL
    }

    @MainActor private func fixture(review: Bool = false) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iScope-search-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = BinaryImage(url: directory.appendingPathComponent("Counter"), relativePath: "Counter", size: 1, architectures: ["arm64"], isMainExecutable: true)
        let methods = [ObjCMethod(className: "ExerciseCounter", selector: "stepCount", typeEncoding: "q16@0:8", address: 0x1000, fileOffset: nil, isClassMethod: false),
                       ObjCMethod(className: "ExerciseCounter", selector: "pedometerSteps", typeEncoding: "q16@0:8", address: 0x1100, fileOffset: nil, isClassMethod: false)]
        let analysis = BinaryAnalysis(image: image, architecture: "arm64", uuid: nil, encrypted: false, imageBase: 0, sliceOffset: 0, sections: [],
                                      classes: [ObjCClass(name: "ExerciseCounter", superclass: "NSObject", address: 0x2000, methods: methods, properties: [], protocols: [], isCategory: false)],
                                      symbols: [], strings: [BinaryString(value: "今日步数", address: 0x3000, section: "__cfstring")], references: [], dependencies: [], warnings: [], elapsed: 0)
        let plan = FeatureSearchPlan(summary: "寻找步数相关方法", appContext: "测试应用", action: "读取",
                                     concepts: [FeatureConcept(label: "步数", role: .feature, terms: ["stepCount", "pedometer", "步数"])], cautions: [])
        let candidates = try FeatureSearchEngine.search([analysis], plan: plan).results
        let assessment = CandidateReview(summary: "保留可复核的候选", assessments: candidates.map {
            .init(id: $0.id, relevance: .likely, reason: "方法名包含检索词", evidenceIndices: [0])
        })
        let executable = directory.appendingPathComponent("codex")
        try JSONEncoder().encode(plan).write(to: executable.appendingPathExtension("plan"))
        try JSONEncoder().encode(assessment).write(to: executable.appendingPathExtension("review"))
        try """
        #!/usr/bin/python3
        import sys,json,pathlib
        if '--version' in sys.argv: print('codex-cli fixture'); sys.exit(0)
        if 'mcp' in sys.argv: print('[]'); sys.exit(0)
        args=sys.argv
        sys.stdin.read()
        schema=json.loads(pathlib.Path(args[args.index('--output-schema')+1]).read_text())
        kind='review' if 'assessments' in schema['properties'] else 'plan'
        with open(__file__+'.calls','a') as f: f.write(kind+'\\n')
        response=pathlib.Path(__file__+'.'+kind).read_text()
        pathlib.Path(args[args.index('--output-last-message')+1]).write_text(response)
        print(json.dumps({'type':'item.completed','item':{'type':'agent_message','text':response}}))
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = AppModel()
        model.artifact = ImportedArtifact(sourceURL: directory.appendingPathComponent("Original.ipa"), name: "Counter", bundleIdentifier: "com.example.counter", version: "1", images: [image], temporaryDirectory: nil)
        model.analyses = [image.id: analysis]; model.selectedImageID = image.id; model.page = .all
        var settings = CodexSettings(); settings.executablePath = executable.path; settings.reviewCandidates = review
        model.codexSettings = settings; model.query = "读取今天的步数"
        return Fixture(model: model, directory: directory, image: image, analysis: analysis, invocationFile: executable.appendingPathExtension("calls"))
    }

    @MainActor private func locate(_ model: AppModel) async throws {
        model.startSmartSearch()
        for _ in 0..<250 {
            if !model.isSmartSearching { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isSmartSearching)
        XCTAssertNil(model.smartError)
        XCTAssertEqual(model.results.count, 2)
    }

    @MainActor func testHookCreationAndRepeatedNavigationKeepResultsAndReview() async throws {
        let fixture = try fixture(review: true); let model = fixture.model
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await locate(model)
        let expected = model.results.map(\.id), query = model.query, plan = model.smartPlan, review = model.smartReview?.summary
        let selected = try XCTUnwrap(model.results.last)
        model.selectedResultID = selected.id
        model.createHookProject(from: selected)
        XCTAssertTrue(model.showHookProject)
        let project = try HookProjectGenerator.write(.init(name: "RetainedHook", bundleIdentifier: "com.example.counter", methods: model.hookSeeds), to: fixture.directory)
        model.workflow.configure(project: project.appendingPathComponent("RetainedHook.xcodeproj"), input: model.artifact?.sourceURL)
        model.showHookProject = false; model.showWorkflow = true; model.showWorkflow = false
        model.page = .all; model.query = query; model.searchAllImages = false
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.results.map(\.id), expected)
        XCTAssertEqual(model.selectedResultID, selected.id)
        XCTAssertEqual(model.smartPlan, plan)
        XCTAssertEqual(model.smartReview?.summary, review)
        XCTAssertEqual(model.featureSearchSessions.count, 1)
        XCTAssertEqual(try String(contentsOf: fixture.invocationFile, encoding: .utf8), "plan\nreview\n")
    }

    @MainActor func testReturningFromStringAndMethodPagesRestoresSelectionWithoutCLI() async throws {
        let fixture = try fixture(); let model = fixture.model
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await locate(model)
        let selected = try XCTUnwrap(model.results.last)
        let expected = model.results.map(\.id), query = model.query
        model.selectedResultID = selected.id
        let clue = try XCTUnwrap(model.smartResponse?.clues.first)
        model.navigateToClue(clue)
        XCTAssertEqual(model.page, .strings)
        try await Task.sleep(for: .milliseconds(250))
        model.page = .all
        XCTAssertEqual(model.results.map(\.id), expected)
        XCTAssertEqual(model.selectedResultID, selected.id)
        XCTAssertEqual(model.query, query)
        model.navigateToMethod(address: selected.address, imageID: selected.imageID)
        XCTAssertEqual(model.page, .methods)
        model.page = .all
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.results.map(\.id), expected, "A pending keyword search must not overwrite the restored list")
        XCTAssertEqual(model.selectedResultID, selected.id)
        XCTAssertEqual(try String(contentsOf: fixture.invocationFile, encoding: .utf8), "plan\n")
    }

    @MainActor func testNewSearchKeepsPreviousTabUntilExplicitlyClosed() async throws {
        let fixture = try fixture(); let model = fixture.model
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await locate(model)
        let first = try XCTUnwrap(model.selectedFeatureSearchID)
        let originalQuery = model.query
        model.selectedResultID = model.results.first?.id
        let selected = model.selectedResultID
        model.query = "上传运动步数"
        XCTAssertFalse(model.isSmartMode)
        XCTAssertEqual(model.featureSearchSessions.count, 1)
        try await locate(model)
        let second = try XCTUnwrap(model.selectedFeatureSearchID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.featureSearchSessions.count, 2)
        model.restoreFeatureSearch(first)
        XCTAssertEqual(model.query, originalQuery)
        XCTAssertEqual(model.selectedResultID, selected)
        model.useKeywordSearch()
        XCTAssertEqual(model.featureSearchSessions.count, 2)
        model.restoreFeatureSearch(first)
        model.closeFeatureSearch(second)
        XCTAssertEqual(model.selectedFeatureSearchID, first)
        XCTAssertEqual(model.results.count, 2)
        model.closeFeatureSearch(first)
        XCTAssertTrue(model.featureSearchSessions.isEmpty)
        XCTAssertFalse(model.isSmartMode)
        XCTAssertEqual(try String(contentsOf: fixture.invocationFile, encoding: .utf8), "plan\nplan\n")
    }

    @MainActor func testRestoredResultUsesOriginalAnalysisAfterArchitectureChange() async throws {
        let fixture = try fixture(); let model = fixture.model
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await locate(model)
        let selected = try XCTUnwrap(model.results.first)
        model.selectedResultID = selected.id; model.page = .overview
        let original = fixture.analysis
        model.analyses[fixture.image.id] = BinaryAnalysis(image: fixture.image, architecture: "arm64e", uuid: nil, encrypted: false, imageBase: 0, sliceOffset: 0,
                                                         sections: [], classes: original.classes, symbols: [], strings: [], references: [], dependencies: [], warnings: [], elapsed: 0)
        model.page = .all
        XCTAssertEqual(model.selectedAnalysis?.architecture, "arm64")
        XCTAssertEqual(model.hookAnalyses.first?.architecture, "arm64")
        model.scheduleSearch(preserveFeatureResults: true)
        XCTAssertTrue(model.isSmartMode)
        XCTAssertEqual(model.selectedResultID, selected.id)
    }

    @MainActor func testCrossImageClueNavigationKeepsSelectedFeatureTab() async throws {
        let fixture = try fixture(); let model = fixture.model
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let otherImage = BinaryImage(url: fixture.directory.appendingPathComponent("Feature"), relativePath: "Frameworks/Feature", size: 1, architectures: ["arm64"], isMainExecutable: false)
        let otherAnalysis = BinaryAnalysis(image: otherImage, architecture: "arm64", uuid: nil, encrypted: false, imageBase: 0, sliceOffset: 0,
                                           sections: [], classes: [], symbols: [], strings: [BinaryString(value: "步数排名", address: 0x4000, section: "__cfstring")],
                                           references: [], dependencies: [], warnings: [], elapsed: 0)
        model.artifact = ImportedArtifact(sourceURL: fixture.directory.appendingPathComponent("Original.ipa"), name: "Counter", bundleIdentifier: "com.example.counter", version: "1", images: [fixture.image, otherImage], temporaryDirectory: nil)
        model.analyses[otherImage.id] = otherAnalysis; model.searchAllImages = true
        try await locate(model)
        let id = model.selectedFeatureSearchID, expected = model.results.map(\.id)
        let selection = try XCTUnwrap(model.results.first?.id)
        model.selectedResultID = selection
        let clue = try XCTUnwrap(model.smartResponse?.clues.first { $0.imageID == otherImage.id })
        model.navigateToClue(clue)
        XCTAssertEqual(model.selectedImageID, otherImage.id)
        XCTAssertEqual(model.selectedFeatureSearchID, id)
        model.page = .all
        XCTAssertEqual(model.selectedImageID, fixture.image.id)
        XCTAssertTrue(model.searchAllImages)
        XCTAssertEqual(model.results.map(\.id), expected)
        XCTAssertEqual(model.selectedResultID, selection)
        XCTAssertEqual(try String(contentsOf: fixture.invocationFile, encoding: .utf8), "plan\n")
    }
}

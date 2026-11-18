import XCTest
@testable import iScopeCore

final class AnalysisTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("iScope-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(chained: Bool = true, architecture: String = "arm64", iOS: Bool = false, relative: Bool = false) throws -> URL {
        let source = directory.appendingPathComponent("Fixture.m")
        try """
        #import <Foundation/Foundation.h>
        @protocol ScopeAuthenticating <NSObject>
        - (const char *)signInWithToken:(id)token;
        @end
        @interface ScopeLoginController : NSObject <ScopeAuthenticating>
        @property(nonatomic, copy) NSString *userName;
        - (const char *)signInWithToken:(id)token;
        - (NSString *)visibleMessage;
        + (int)loginVersion;
        @end
        @implementation ScopeLoginController
        - (const char *)signInWithToken:(id)token { return "https://example.test/api/login"; }
        - (NSString *)visibleMessage { return @"登录成功"; }
        + (int)loginVersion { return 7; }
        @end
        @interface ScopeLoginController (Payment)
        - (int)submitPayment;
        @end
        @implementation ScopeLoginController (Payment)
        - (int)submitPayment { return [ScopeLoginController loginVersion]; }
        @end
        """.write(to: source, atomically: true, encoding: .utf8)
        let binary = directory.appendingPathComponent("Fixture-\(architecture)-\(chained).dylib")
        var arguments = ["clang", "-arch", architecture, "-dynamiclib", "-fobjc-arc", "-O0", "-Wl,-no_objc_category_merging", "-framework", "Foundation", source.path, "-o", binary.path]
        if iOS {
            let sdk = try ProcessRunner.run("/usr/bin/xcrun", ["--sdk", "iphoneos", "--show-sdk-path"]).trimmingCharacters(in: .whitespacesAndNewlines)
            arguments += ["-target", "\(architecture)-apple-ios16.0", "-isysroot", sdk]
        } else { arguments += ["-mmacosx-version-min=14.0"] }
        if relative { arguments += ["-fobjc-relative-method-lists"] }
        arguments += [chained ? "-Wl,-fixup_chains" : "-Wl,-no_fixup_chains"]
        _ = try ProcessRunner.run("/usr/bin/xcrun", arguments)
        return binary
    }

    func testChainedFixupsClassesMethodsAndChineseReferences() throws {
        let url = try fixture()
        let imported = try ArtifactImporter.load(url)
        let analysis = try MachOAnalyzer.analyze(XCTUnwrap(imported.images.first))
        let cls = try XCTUnwrap(analysis.classes.first { $0.name == "ScopeLoginController" })
        XCTAssertEqual(cls.superclass, "NSObject")
        XCTAssertTrue(cls.protocols.contains("ScopeAuthenticating"))
        XCTAssertTrue(cls.properties.contains { $0.name == "userName" })
        let login = try XCTUnwrap(cls.methods.first { $0.selector == "signInWithToken:" })
        XCTAssertFalse(login.isClassMethod)
        XCTAssertNotNil(login.fileOffset)
        XCTAssertTrue(cls.methods.contains { $0.selector == "loginVersion" && $0.isClassMethod })
        XCTAssertTrue(analysis.classes.contains { $0.name == "ScopeLoginController(Payment)" && $0.isCategory }, "Recovered: \(analysis.classes.map(\.name)); \(analysis.warnings)")
        XCTAssertTrue(analysis.references.contains { $0.function == login.address && $0.label == "https://example.test/api/login" && $0.kind == .string })
        let message = try XCTUnwrap(cls.methods.first { $0.selector == "visibleMessage" })
        XCTAssertTrue(analysis.strings.contains { $0.value == "登录成功" })
        XCTAssertTrue(analysis.references.contains { $0.function == message.address && $0.label == "登录成功" && $0.kind == .string })
        let matches = try SearchEngine.search([analysis], query: "登录", kind: .method)
        XCTAssertTrue(matches.results.contains { $0.address == login.address })
        XCTAssertTrue(matches.results.contains { $0.address == message.address && $0.evidence.contains("方法引用的字符串命中") })
        XCTAssertFalse(matches.expandedTerms.isEmpty)
    }

    func testClassicPointersAndExportRoundTrip() throws {
        let imported = try ArtifactImporter.load(fixture(chained: false))
        let analysis = try MachOAnalyzer.analyze(XCTUnwrap(imported.images.first))
        XCTAssertTrue(analysis.methods.contains { $0.selector == "signInWithToken:" })
        let data = try AnalysisExporter.data([analysis], format: .json)
        let roundTrip = try JSONDecoder().decode([BinaryAnalysis].self, from: data)
        XCTAssertEqual(roundTrip.first?.methods.count, analysis.methods.count)
        let csv = String(decoding: try AnalysisExporter.data([analysis], format: .csv), as: UTF8.self)
        XCTAssertTrue(csv.contains("vm_address,file_offset,type_encoding"))
        XCTAssertTrue(csv.contains("signInWithToken:"))
        let headers = String(decoding: try AnalysisExporter.data([analysis], format: .headers), as: UTF8.self)
        XCTAssertTrue(headers.contains("@interface ScopeLoginController :"))
        XCTAssertTrue(headers.contains("arg1"))
        XCTAssertFalse(headers.contains("(id)signInWithToken:;"))
    }

    func testIOSArm64eAndRelativeMethods() throws {
        for architecture in ["arm64", "arm64e"] {
            let url = try fixture(architecture: architecture, iOS: true, relative: true)
            let image = try XCTUnwrap(ArtifactImporter.load(url).images.first)
            let analysis = try MachOAnalyzer.analyze(image)
            XCTAssertEqual(analysis.architecture, architecture)
            let cls = try XCTUnwrap(analysis.classes.first { $0.name == "ScopeLoginController" }, analysis.warnings.joined(separator: "; "))
            XCTAssertTrue(cls.methods.contains { $0.selector == "signInWithToken:" && $0.address != 0 })
            XCTAssertTrue(cls.methods.contains { $0.selector == "loginVersion" && $0.isClassMethod })
            XCTAssertTrue(analysis.classes.contains { $0.name == "ScopeLoginController(Payment)" })
        }
    }

    func testSwiftSymbolDemangling() throws {
        let source = directory.appendingPathComponent("Fixture.swift"), binary = directory.appendingPathComponent("SwiftFixture.dylib")
        try "public class CheckoutService { public init() {} ; public func completePurchase() -> String { \"payment confirmed\" } }".write(to: source, atomically: true, encoding: .utf8)
        _ = try ProcessRunner.run("/usr/bin/xcrun", ["swiftc", "-emit-library", "-module-name", "ScopeFixture", "-target", "arm64-apple-macos14.0", source.path, "-o", binary.path])
        let image = try XCTUnwrap(ArtifactImporter.load(binary).images.first)
        let analysis = try MachOAnalyzer.analyze(image)
        XCTAssertTrue(analysis.symbols.contains { $0.isSwift && $0.name.contains("CheckoutService.completePurchase") })
        XCTAssertTrue(try SearchEngine.search([analysis], query: "支付", kind: .symbol).results.contains { $0.title.contains("completePurchase") })
    }

    func testUniversalArchitectureSelectionAndUnsupportedArchitecture() throws {
        let arm = try fixture(), intel = try fixture(architecture: "x86_64")
        let universal = directory.appendingPathComponent("Universal")
        _ = try ProcessRunner.run("/usr/bin/xcrun", ["lipo", "-create", arm.path, intel.path, "-output", universal.path])
        let image = try XCTUnwrap(ArtifactImporter.load(universal).images.first)
        XCTAssertEqual(Set(image.architectures), Set(["arm64", "x86_64"]))
        let armAnalysis = try MachOAnalyzer.analyze(image)
        XCTAssertEqual(armAnalysis.architecture, "arm64")
        XCTAssertGreaterThan(armAnalysis.sliceOffset, 0)
        let intelAnalysis = try MachOAnalyzer.analyze(image, architecture: "x86_64")
        XCTAssertEqual(intelAnalysis.architecture, "x86_64")
        XCTAssertTrue(intelAnalysis.methods.contains { $0.selector == "signInWithToken:" })
        XCTAssertThrowsError(try MachOAnalyzer.analyze(image, architecture: "arm"))
    }

    func testIPAImportAndArchiveTraversalRejection() throws {
        let binary = try fixture()
        let app = directory.appendingPathComponent("package/Payload/Scope.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: app.appendingPathComponent("Scope"))
        let info: [String: Any] = ["CFBundleExecutable": "Scope", "CFBundleIdentifier": "test.iscope.fixture", "CFBundleDisplayName": "Scope Fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        let ipa = directory.appendingPathComponent("Scope.ipa")
        _ = try ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.deletingLastPathComponent().path, ipa.path])
        let imported = try ArtifactImporter.load(ipa)
        defer { if let temp = imported.temporaryDirectory { try? FileManager.default.removeItem(at: temp) } }
        XCTAssertEqual(imported.name, "Scope Fixture")
        XCTAssertEqual(imported.images.count, 1)
        XCTAssertTrue(imported.images[0].isMainExecutable)
        // Change a same-length central-directory name without relying on the extractor's path handling.
        var malicious = try Data(contentsOf: ipa)
        let needle = Data("Payload/Scope.app/Scope".utf8)
        guard let range = malicious.range(of: needle, options: .backwards) else { return XCTFail("Missing archive fixture entry") }
        let bad = "../" + String(repeating: "x", count: needle.count - 3)
        malicious.replaceSubrange(range, with: Data(bad.utf8))
        let badURL = directory.appendingPathComponent("Bad.ipa")
        try malicious.write(to: badURL)
        XCTAssertThrowsError(try ArtifactImporter.load(badURL))
    }

    func testMalformedMachOAndSearchErrorsDoNotCrash() throws {
        let url = directory.appendingPathComponent("truncated")
        try Data([0xcf, 0xfa, 0xed, 0xfe]).write(to: url)
        XCTAssertThrowsError(try ArtifactImporter.load(url))
        var header = Data(repeating: 0, count: 32)
        header.replaceSubrange(0..<4, with: [0xcf, 0xfa, 0xed, 0xfe])
        header.replaceSubrange(16..<20, with: [0xff, 0xff, 0xff, 0x7f])
        try header.write(to: url)
        let image = try XCTUnwrap(ArtifactImporter.load(url).images.first)
        XCTAssertThrowsError(try MachOAnalyzer.analyze(image))
        var options = SearchOptions(); options.regularExpression = true
        XCTAssertThrowsError(try SearchEngine.search([], query: "[", options: options))
    }

    func testTypeDecoderUnderstandsOffsetsAndPointers() {
        XCTAssertEqual(ObjCTypeDecoder.types("v24@0:8@16"), ["void", "id", "SEL", "id"])
        XCTAssertEqual(ObjCTypeDecoder.types("@32@0:8^i16B24"), ["id", "id", "SEL", "int *", "BOOL"])
    }
}

import XCTest
@testable import iScopeCore

final class HookProjectTests: XCTestCase {
    private func method(_ selector: String, encoding: String, className: String = "SampleController", isClass: Bool = false) -> ObjCMethod {
        ObjCMethod(className: className, selector: selector, typeEncoding: encoding, address: 0x100001000, fileOffset: 0x1000, isClassMethod: isClass)
    }

    func testSignaturesAndCategoryNormalization() throws {
        let signature = try HookProjectGenerator.signature(for: method("submit:enabled:", encoding: "B28@0:8@16B24"))
        XCTAssertEqual(signature.returnType, "BOOL")
        XCTAssertEqual(signature.argumentTypes, ["id", "BOOL"])
        XCTAssertEqual(HookProjectGenerator.targetClassName(method("run", encoding: "v16@0:8", className: "SampleController(Extra)")), "SampleController")
        XCTAssertEqual(try HookProjectGenerator.signature(for: method("bounds", encoding: "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8")).returnType, "CGRect")
        XCTAssertThrowsError(try HookProjectGenerator.signature(for: method("unknown", encoding: "{PrivateLayout=ii}16@0:8")))
        XCTAssertThrowsError(try HookProjectGenerator.signature(for: method("incorrectLayout", encoding: "{CGRect=ii}16@0:8")))
        XCTAssertEqual(try HookProjectGenerator.signature(for: method("copyWithZone:", encoding: "@24@0:8^{_NSZone=}16")).argumentTypes, ["void *"])
        XCTAssertThrowsError(try HookProjectGenerator.signature(for: method("bad:", encoding: "v16@0:8")))
    }

    func testValidationAndNonDestructiveCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iScope-hook-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let methods = [method("run", encoding: "v16@0:8")]
        XCTAssertThrowsError(try HookProjectGenerator.files(for: .init(name: "../Escape", bundleIdentifier: "com.example.app", methods: methods)))
        XCTAssertThrowsError(try HookProjectGenerator.files(for: .init(name: "ValidHook", bundleIdentifier: "invalid\nvalue", methods: methods)))
        let config = HookProjectConfiguration(name: "ValidHook", bundleIdentifier: "com.example.app", methods: methods)
        let url = try HookProjectGenerator.write(config, to: directory)
        let source = try String(contentsOf: url.appendingPathComponent("Hooks.m"), encoding: .utf8)
        XCTAssertTrue(source.contains("class_addMethod"))
        XCTAssertTrue(source.contains("IScopeOriginal_0(self, _cmd);"))
        XCTAssertTrue(source.contains("com.example.app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("ValidHook.xcodeproj/project.pbxproj").path))
        XCTAssertThrowsError(try HookProjectGenerator.write(config, to: directory))
        XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("Hooks.m"), encoding: .utf8), source)
    }

    func testGeneratedProjectBuildsForIOS() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iScope-hook-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = HookProjectConfiguration(name: "VerifiedHook", bundleIdentifier: "com.example.test", methods: [
            method("submit:enabled:", encoding: "B28@0:8@16B24"),
            method("sendMessage:", encoding: "v24@0:8@16"),
            method("bounds", encoding: "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8"),
            method("service", encoding: "@16@0:8", isClass: true),
            method("copyWithZone:", encoding: "@24@0:8^{_NSZone=}16")
        ])
        let url = try HookProjectGenerator.write(config, to: directory)
        let derived = directory.appendingPathComponent("DerivedData")
        do {
            _ = try ProcessRunner.run("/usr/bin/xcodebuild", ["-quiet", "-project", url.appendingPathComponent("VerifiedHook.xcodeproj").path,
                                                            "-scheme", "VerifiedHook", "-configuration", "Release", "-sdk", "iphoneos",
                                                            "-destination", "generic/platform=iOS", "-derivedDataPath", derived.path, "build"])
        } catch { return XCTFail("Generated Xcode project did not build: \(error.localizedDescription)") }
        let product = derived.appendingPathComponent("Build/Products/Release-iphoneos/VerifiedHook.dylib")
        XCTAssertTrue(FileManager.default.fileExists(atPath: product.path))
        let image = try XCTUnwrap(ArtifactImporter.load(product).images.first)
        XCTAssertEqual(image.architectures, ["arm64"])
    }
}

#!/usr/bin/env python3
"""Generate the dependency-free Xcode project. Run after adding Swift files."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
objects = {}


def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def add(object_name, isa, **values):
    key = uid(object_name)
    objects[key] = dict(isa=isa, **values)
    return key


def configurations(name, settings):
    ids = []
    for mode in ("Debug", "Release"):
        values = dict(settings)
        values.update(SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O",
                      DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym")
        if mode == "Debug":
            values.update(ENABLE_TESTABILITY="YES", SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG")
        ids.append(add(name + mode, "XCBuildConfiguration", buildSettings=values, name=mode))
    return add(name + "configs", "XCConfigurationList", buildConfigurations=ids,
               defaultConfigurationIsVisible="0", defaultConfigurationName="Release")


products = []
groups = []
targets = []
common = dict(SWIFT_VERSION="5.0", MACOSX_DEPLOYMENT_TARGET="14.0", SDKROOT="macosx",
              CLANG_ENABLE_MODULES="YES", SWIFT_STRICT_CONCURRENCY="targeted")
core_id = uid("targetiScopeCore")
core_product = uid("productiScopeCore")
for name, source_dir, product_type, filename in [
    ("iScopeCore", "Sources/iScopeCore", "com.apple.product-type.library.static", "libiScopeCore.a"),
    ("iScope", "Sources/iScopeApp", "com.apple.product-type.application", "iScope.app"),
    ("iScopeCoreTests", "Tests/iScopeCoreTests", "com.apple.product-type.bundle.unit-test", "iScopeCoreTests.xctest"),
]:
    file_ids = []
    build_ids = []
    for path in sorted((root / source_dir).glob("*.swift")):
        rel = str(path.relative_to(root))
        file_ref = add(rel, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=path.name, sourceTree="<group>")
        file_ids.append(file_ref)
        build_ids.append(add("build" + rel, "PBXBuildFile", fileRef=file_ref))
    groups.append(add("group" + name, "PBXGroup", children=file_ids, path=source_dir, sourceTree="<group>"))
    product = add("product" + name, "PBXFileReference", explicitFileType={"iScopeCore": "archive.ar", "iScope": "wrapper.application", "iScopeCoreTests": "wrapper.cfbundle"}[name],
                  includeInIndex="0", path=filename, sourceTree="BUILT_PRODUCTS_DIR")
    products.append(product)
    dependencies, frameworks = [], []
    if name != "iScopeCore":
        proxy = add("proxy" + name, "PBXContainerItemProxy", containerPortal=uid("project"), proxyType="1", remoteGlobalIDString=core_id, remoteInfo="iScopeCore")
        dependencies.append(add("dep" + name, "PBXTargetDependency", target=core_id, targetProxy=proxy))
        frameworks.append(add("linkcore" + name, "PBXBuildFile", fileRef=core_product))
    phases = [add("sources" + name, "PBXSourcesBuildPhase", buildActionMask="2147483647", files=build_ids, runOnlyForDeploymentPostprocessing="0"),
              add("frameworks" + name, "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=frameworks, runOnlyForDeploymentPostprocessing="0")]
    settings = dict(common, PRODUCT_NAME="$(TARGET_NAME)", CODE_SIGN_IDENTITY="-", CODE_SIGN_STYLE="Manual")
    if name == "iScopeCore":
        settings.update(DEFINES_MODULE="YES", SKIP_INSTALL="YES", MACH_O_TYPE="staticlib", SWIFT_INSTALL_OBJC_HEADER="NO")
    elif name == "iScope":
        settings.update(PRODUCT_BUNDLE_IDENTIFIER="dev.iscope.mac", INFOPLIST_FILE="Resources/Info.plist", ENABLE_APP_SANDBOX="NO",
                        ENABLE_HARDENED_RUNTIME="YES", LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/../Frameworks",
                        SWIFT_INCLUDE_PATHS="$(BUILT_PRODUCTS_DIR)")
        icon = add("icon", "PBXFileReference", lastKnownFileType="image.icns", path="Resources/AppIcon.icns", sourceTree="SOURCE_ROOT")
        icon_build = add("iconbuild", "PBXBuildFile", fileRef=icon)
        tools = add("hooktools", "PBXFileReference", lastKnownFileType="folder", path="Sources/iScopeCore/Resources/HookTools", sourceTree="SOURCE_ROOT")
        tools_build = add("hooktoolsbuild", "PBXBuildFile", fileRef=tools)
        phases.append(add("resources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[icon_build, tools_build], runOnlyForDeploymentPostprocessing="0"))
    else:
        settings.update(PRODUCT_BUNDLE_IDENTIFIER="dev.iscope.tests", GENERATE_INFOPLIST_FILE="YES", SWIFT_INCLUDE_PATHS="$(BUILT_PRODUCTS_DIR)")
        tools_test_build = add("hooktoolsbuildtests", "PBXBuildFile", fileRef=uid("hooktools"))
        phases.append(add("testresources", "PBXResourcesBuildPhase", buildActionMask="2147483647", files=[tools_test_build], runOnlyForDeploymentPostprocessing="0"))
    targets.append(add("target" + name, "PBXNativeTarget", buildConfigurationList=configurations(name, settings), buildPhases=phases,
                       buildRules=[], dependencies=dependencies, name=name, productName=name, productReference=product, productType=product_type))

resources = add("info", "PBXFileReference", lastKnownFileType="text.plist.xml", path="Resources/Info.plist", sourceTree="<group>")
product_group = add("products", "PBXGroup", children=products, name="Products", sourceTree="<group>")
main_group = add("main", "PBXGroup", children=groups + [resources, uid("icon"), uid("hooktools"), product_group], sourceTree="<group>")
project = add("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "1600"},
              buildConfigurationList=configurations("project", common), compatibilityVersion="Xcode 14.0", developmentRegion="zh_CN",
              hasScannedForEncodings="0", knownRegions=["zh_CN", "en", "Base"], mainGroup=main_group,
              productRefGroup=product_group, projectDirPath="", projectRoot="", targets=targets)


def render(value, level=0):
    if isinstance(value, dict):
        return "{\n" + "".join("\t" * (level + 1) + json.dumps(k) + " = " + render(v, level + 1) + ";\n" for k, v in value.items()) + "\t" * level + "}"
    if isinstance(value, list):
        return "(" + ", ".join(render(v, level) for v in value) + ("," if value else "") + ")"
    return json.dumps(value, ensure_ascii=False)


project_path = root / "iScope.xcodeproj"
project_path.mkdir(exist_ok=True)
(project_path / "project.pbxproj").write_text("// !$*UTF8*$!\n" + render(dict(archiveVersion="1", classes={}, objectVersion="56", objects=objects, rootObject=project)) + "\n")
scheme_dir = project_path / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)


def reference(name, buildable):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target" + name)}" BuildableName="{buildable}" BlueprintName="{name}" ReferencedContainer="container:iScope.xcodeproj"/>'


(scheme_dir / "iScope.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
    <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference("iScope", "iScope.app")}</BuildActionEntry>
  </BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{reference("iScopeCoreTests", "iScopeCoreTests.xctest")}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference("iScope", "iScope.app")}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference("iScope", "iScope.app")}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print("Generated iScope.xcodeproj (app, core, tests).")

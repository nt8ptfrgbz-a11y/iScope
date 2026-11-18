#!/usr/bin/env python3
"""Build LookinServer's Objective-C Core as an injectable iOS dylib.

Requires a local checkout of https://github.com/QMUI/LookinServer and Xcode.
Does not need the target app's source code, CocoaPods, or a signing identity.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


def run(*arguments):
    return subprocess.check_output([str(value) for value in arguments], text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="LookinServer repository")
    parser.add_argument("--output", required=True, type=Path, help="New .dylib output path")
    parser.add_argument("--arch", action="append", choices=("arm64", "arm64e"))
    parser.add_argument("--minimum-ios", default="15.0")
    options = parser.parse_args()
    source = options.source.expanduser().resolve()
    output = options.output.expanduser().resolve()
    report = output.with_suffix(".build.json")
    if output.suffix != ".dylib":
        parser.error("--output must end in .dylib")
    if output.exists() or report.exists():
        parser.error("Output already exists; choose a new --output path")
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", options.minimum_ios):
        parser.error("--minimum-ios must be a version such as 15.0")
    roots = [source / "Src" / "Main", source / "Src" / "Base"]
    if not all(root.is_dir() for root in roots):
        parser.error("--source must be a LookinServer checkout with Src/Main and Src/Base")
    sources = sorted(path for root in roots for path in root.rglob("*")
                     if path.suffix in (".m", ".mm") and path.is_file())
    if not sources:
        parser.error("No Objective-C source files found")
    headers = sorted({path.parent for root in roots for path in root.rglob("*.h")})
    architectures = list(dict.fromkeys(options.arch or ["arm64"]))
    sdk = run("/usr/bin/xcrun", "--sdk", "iphoneos", "--show-sdk-path")
    compiler = run("/usr/bin/xcrun", "--sdk", "iphoneos", "--find", "clang")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".lookin-build-", dir=output.parent) as directory:
        work = Path(directory)
        slices = []
        for architecture in architectures:
            destination = work / (architecture + ".dylib")
            command = [compiler, "-dynamiclib", "-arch", architecture, "-isysroot", sdk,
                       "-miphoneos-version-min=" + options.minimum_ios,
                       "-fobjc-arc", "-fblocks", "-fmodules", "-g", "-O0",
                       "-fmodules-cache-path=" + str(work / "Modules"),
                       "-DSHOULD_COMPILE_LOOKIN_SERVER=1", "-DDEBUG=1",
                       "-include", "UIKit/UIKit.h", "-Wno-deprecated-declarations",
                       "-Wl,-install_name,@rpath/" + output.name,
                       "-Wl,-no_adhoc_codesign"]
            for header in headers:
                command += ["-I", str(header)]
            command += [str(path) for path in sources]
            for framework in ("Foundation", "UIKit", "QuartzCore", "CoreGraphics"):
                command += ["-framework", framework]
            command += ["-o", str(destination)]
            print(f"Building LookinServer Core: {architecture}, {len(sources)} files", flush=True)
            subprocess.run(command, check=True)
            symbols = run("/usr/bin/xcrun", "nm", "-gU", destination)
            for symbol in ("_OBJC_CLASS_$_LKS_ConnectionManager", "_OBJC_CLASS_$_LookinDisplayItem"):
                if symbol not in symbols:
                    raise RuntimeError("Missing LookinServer implementation: " + symbol)
            slices.append(destination)
        combined = work / output.name
        subprocess.run(["/usr/bin/xcrun", "lipo", "-create", *map(str, slices),
                        "-output", str(combined)], check=True)
        # Link directly from all translation units so +load methods and categories
        # survive; loading the dylib starts LKS_ConnectionManager automatically.
        dependencies = run("/usr/bin/xcrun", "otool", "-L", combined)
        commit = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"],
                                capture_output=True, text=True)
        document = {"source": str(source), "repository": "https://github.com/QMUI/LookinServer",
                    "commit": commit.stdout.strip() if commit.returncode == 0 else None,
                    "architectures": architectures, "minimumIOS": options.minimum_ios,
                    "swiftReflectionEnabled": False, "signingRequired": True,
                    "sha256": hashlib.sha256(combined.read_bytes()).hexdigest(),
                    "dependencies": dependencies}
        # Exclusive publication keeps existing artifacts intact.
        with output.open("xb") as target:
            target.write(combined.read_bytes())
        with report.open("x") as target:
            json.dump(document, target, ensure_ascii=False, indent=2)
    print("Built: " + str(output))
    print("Report: " + str(report))


if __name__ == "__main__":
    main()

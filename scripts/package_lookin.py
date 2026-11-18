#!/usr/bin/env python3
"""Inject a prebuilt LookinServer dylib, then sign a new testing IPA.

Reuses iScope's archive validation, dependency checks, inside-out signing and
final IPA signature verification. Does not install or launch the target app.
"""
import argparse
import datetime
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Sources/iScopeCore/Resources/HookTools/lib"))
from package import package_ipa
from signing import input_bundle_id, resign_ipa, signing_assets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path, help="Decrypted .ipa or .app")
    parser.add_argument("--dylib", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--bundle-id", help="Default: original Bundle ID + .lookin")
    parser.add_argument("--display-name", default="")
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--identity", help="Signing certificate SHA-1")
    parser.add_argument("--device-udid", action="append", default=[])
    parser.add_argument("--profile-search-directory", action="append", default=[], type=Path)
    options = parser.parse_args()
    source = options.input.expanduser().resolve()
    dylib = options.dylib.expanduser().resolve()
    root = options.output_directory.expanduser().resolve()
    if not source.exists() or not dylib.is_file():
        parser.error("Input app/IPA or dylib does not exist")
    if root == source or (source.is_dir() and root.is_relative_to(source)):
        parser.error("Output directory must be outside the input app")
    original_id = input_bundle_id(source)
    bundle_id = options.bundle_id or (original_id if original_id.endswith(".lookin") else original_id + ".lookin")
    previous = Path.home() / "Downloads/ios-hook-tools"
    assets = signing_assets(options.profile.expanduser().resolve() if options.profile else None,
                            bundle_id, options.identity, options.device_udid,
                            search_dirs=[source.parent, previous, previous / "profiles",
                                         *options.profile_search_directory])
    directory = root / (datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    directory.mkdir(parents=True)
    result = {"input": str(source), "dylib": str(dylib), "bundleIdentifier": bundle_id,
              "unsignedIPA": None, "signedIPA": None, "installed": False,
              "deviceTested": False}
    result_path = directory / "result.json"

    def save():
        result_path.write_text(json.dumps(result, ensure_ascii=False, indent=2))

    save()
    try:
        unsigned = directory / "Lookin-unsigned.ipa"
        package_ipa(source, [dylib], unsigned)
        result["unsignedIPA"] = str(unsigned)
        save()
        signed = directory / "Lookin-signed.ipa"
        resign_ipa(unsigned, signed, assets, bundle_id,
                   display_name=options.display_name or None)
        result["signedIPA"] = str(signed)
        result["signatureVerified"] = True
        save()
    except Exception as error:
        result["error"] = str(error)
        save()
        raise
    print("Signed IPA: " + str(signed))
    print("Result: " + str(result_path))


if __name__ == "__main__":
    main()

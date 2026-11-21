import os
from pathlib import Path
import re
import tempfile

from common import prepare_output, publish, run, sha256
from macho import check_device_images, inspect


def default_build_output(source):
    """Place the dylib beside the first source without replacing earlier builds."""
    output = source.with_suffix(".dylib")
    index = 2
    while output.exists() or output.with_suffix(".dylib.report.json").exists():
        output = source.with_name(f"{source.stem}-{index}.dylib")
        index += 1
    return output


def build_hook(sources, output, *, architectures=None, min_ios="15.0", frameworks=None,
               include_dirs=(), cflags=(), ldflags=(), theos=None):
    prepare_output(output)
    if output.suffix != ".dylib":
        raise ValueError("编译输出须为 .dylib")
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", min_ios):
        raise ValueError("min_ios 格式应为 15.0")
    architectures = architectures or ["arm64"]
    if any(arch not in ("arm64", "arm64e") for arch in architectures):
        raise ValueError("架构支持 arm64、arm64e")
    if not sources or any(not path.is_file() for path in sources):
        raise ValueError("请提供存在的 Hook 源码文件")
    if any(path.suffix not in (".m", ".mm", ".c", ".cc", ".cpp", ".x", ".xm") for path in sources):
        raise ValueError("支持 .m/.mm/.c/.cc/.cpp 和 Logos .x/.xm")
    sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path").decode().strip()
    frameworks = frameworks if frameworks is not None else ["Foundation", "UIKit"]
    source_hashes = {str(path): sha256(path) for path in sources}
    with tempfile.TemporaryDirectory(prefix=".build-", dir=output.parent) as directory:
        stage = Path(directory)
        objects = []
        use_cxx = any(path.suffix in (".mm", ".cc", ".cpp", ".xm") for path in sources)
        arch_args = [item for arch in architectures for item in ("-arch", arch)]
        common = ["-isysroot", sdk, f"-miphoneos-version-min={min_ios}", *arch_args]
        for index, original in enumerate(sources):
            source = original
            if original.suffix in (".x", ".xm"):
                root = Path(theos or os.environ.get("THEOS", "~/theos")).expanduser().resolve()
                logos = root / "bin/logos.pl"
                if not logos.is_file():
                    raise ValueError("Logos 源码需要 Theos：设置 THEOS 或 --theos")
                source = stage / f"logos-{index}{'.mm' if original.suffix == '.xm' else '.m'}"
                source.write_bytes(run("perl", logos, "-c", "generator=internal", original))
            objc = source.suffix in (".m", ".mm")
            cxx = source.suffix in (".mm", ".cc", ".cpp")
            compiler = "clang++" if cxx else "clang"
            flags = ["-std=c++17" if cxx else "-std=gnu11", "-O2", "-Wall", "-Wextra", "-fblocks"]
            if objc:
                flags.append("-fobjc-arc")
            for include in (original.parent, *include_dirs):
                flags.extend(["-I", str(include)])
            obj = stage / f"{index}.o"
            print(f"编译：{original.name}", flush=True)
            run("xcrun", "--sdk", "iphoneos", compiler, *common, *flags, *cflags,
                "-c", source, "-o", obj)
            objects.append(obj)
        binary = stage / output.name
        framework_args = [item for framework in frameworks for item in ("-framework", framework)]
        run("xcrun", "--sdk", "iphoneos", "clang++" if use_cxx else "clang", *common,
            "-dynamiclib", "-install_name", f"@rpath/{output.name}",
            *objects, *framework_args, *ldflags, "-o", binary)
        check_device_images(inspect(binary), 6)
        return publish(binary, output, {"step": "build", "sources": source_hashes,
                       "architectures": architectures, "min_ios": min_ios,
                       "frameworks": frameworks, "requires_resigning": True})

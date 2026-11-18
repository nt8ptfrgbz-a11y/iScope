"""Check bundled launch-time dylib paths; this is not a device dyld emulator."""
from pathlib import Path
import os

from common import app_info
from macho import inspect


def check_dependencies(app):
    app = app.resolve()
    executable = app / app_info(app)["CFBundleExecutable"]
    cache, checked, optional_missing, system = {}, set(), set(), set()
    edge_count = 0

    def images(path):
        if path not in cache:
            cache[path] = inspect(path)
        return cache[path]

    def expand(value, loader):
        for token, base in (("@executable_path", executable.parent), ("@loader_path", loader.parent)):
            if value == token or value.startswith(token + "/"):
                return (base / value[len(token):].lstrip("/")).resolve()
        return Path(os.path.normpath(value)) if value.startswith("/") else None

    def os_path(path):
        return str(path).startswith(("/System/Library/", "/usr/lib/"))

    def visit(path, image, inherited=(), ancestors=()):
        nonlocal edge_count
        rpaths = tuple(dict.fromkeys(
            [value for raw in image["rpaths"] if (value := expand(raw, path)) is not None]
            + list(inherited)))
        key = (path, image["cpu"], image["subtype"], rpaths)
        if key in checked or path in ancestors:
            return
        checked.add(key)
        for dependency in image["dependencies"]:
            edge_count += 1
            name = dependency["path"]
            direct = expand(name, path)
            candidates = ([direct] if direct is not None else
                          [Path(os.path.normpath(root / name[7:])) for root in rpaths]
                          if name.startswith("@rpath/") else [])
            candidates = [candidate.resolve() if candidate.is_relative_to(app) else candidate
                          for candidate in candidates]
            # Absolute OS install names reside in the device shared cache, not
            # necessarily on this Mac. Only Swift runtime names are assumed for
            # an @rpath fallback; an arbitrary missing library must still fail.
            system_candidate = next((candidate for candidate in candidates if os_path(candidate)
                                     and (name.startswith("/") or
                                          (name.startswith("@rpath/libswift")
                                           and candidate.parent == Path("/usr/lib/swift")
                                           and candidate.suffix == ".dylib"))), None)
            target = next((candidate for candidate in candidates
                           if candidate.is_relative_to(app) and candidate.is_file()), None)
            if target is None:
                if system_candidate is not None:
                    system.add(str(system_candidate))
                    continue
                if dependency["optional"]:
                    optional_missing.add((str(path.relative_to(app)), name))
                    continue
                raise ValueError(f"缺少必需动态库：{path.relative_to(app)} → {name}。"
                                 "此 IPA 会在加载时闪退；请补齐依赖或修正加载路径后再打包/签名。"
                                 "重签名不能补齐缺失的库。")
            candidates_images = images(target)
            subtype = image["subtype"] & 0xFFFFFF
            compatible = [item for item in candidates_images if item["cpu"] == image["cpu"]
                          and item["subtype"] & 0xFFFFFF in (subtype, 0) and item["kind"] == 6]
            if not compatible:
                raise ValueError(f"动态库缺少兼容架构或不是 MH_DYLIB：{target.relative_to(app)}"
                                 f"（引用者 {path.relative_to(app)}）")
            selected = min(compatible, key=lambda item: (item["subtype"] & 0xFFFFFF) != subtype)
            visit(target, selected, rpaths, (*ancestors, path))

    main_images = images(executable)
    if not main_images or any(image["kind"] != 2 for image in main_images):
        raise ValueError("主程序不是有效的 Mach-O executable")
    for image in main_images:
        visit(executable, image)
    return {"scope": "main_executable_load_commands", "images_checked": len(checked),
            "dependencies_checked": edge_count,
            "missing_optional": [{"loader": loader, "path": name}
                                 for loader, name in sorted(optional_missing)],
            "system_paths_assumed": len(system),
            "limitations": ["不验证设备系统库、导出符号、运行期 dlopen 或扩展进程；需要真机启动验证"]}

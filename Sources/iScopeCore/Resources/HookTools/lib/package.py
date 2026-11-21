from pathlib import Path
import shutil
import tempfile
import unicodedata
import zipfile

from common import app_info, pack, prepare_output, publish, sha256, stage_input
from macho import check_device_images, inspect, patch_loads
from dependencies import check_dependencies


def package_ipa(source, dylibs, output):
    prepare_output(output, source)
    if not dylibs or len({path.name for path in dylibs}) != len(dylibs):
        raise ValueError("至少提供一个 dylib，且文件名不能重复")
    for dylib in dylibs:
        if dylib.suffix != ".dylib" or not dylib.is_file():
            raise ValueError(f"缺少 dylib：{dylib}")
        check_device_images(inspect(dylib), 6)
    print("准备 App 副本…", flush=True)
    with tempfile.TemporaryDirectory(prefix=".package-", dir=output.parent) as directory:
        stage = Path(directory)
        app = stage_input(source, stage / "unpacked")
        info = app_info(app)
        executable = app / info["CFBundleExecutable"]
        source_hash = sha256(executable)
        images = inspect(executable)
        check_device_images(images, 2)
        required_archs = {(item["cpu"], item["subtype"] & 0xFFFFFF) for item in images}
        frameworks = app / "Frameworks"
        if frameworks.is_symlink():
            raise ValueError("主 App 的 Frameworks 不能是符号链接")
        frameworks.mkdir(exist_ok=True)
        embedded_hashes = {}
        for dylib in dylibs:
            archs = {(item["cpu"], item["subtype"] & 0xFFFFFF) for item in inspect(dylib)}
            if not required_archs.issubset(archs):
                raise ValueError(f"{dylib.name} 缺少主程序架构，请用 --arch arm64 --arch arm64e 等匹配编译")
            target = frameworks / dylib.name
            if target.exists() or target.is_symlink():
                raise ValueError(f"App 内已存在 {dylib.name}，请使用未注入该库的输入")
            shutil.copy2(dylib, target)
            embedded_hashes[f"Payload/{app.name}/Frameworks/{dylib.name}"] = sha256(target)
        loads = [f"@executable_path/Frameworks/{path.name}" for path in dylibs]
        patches = patch_loads(executable, loads)
        dependency_check = check_dependencies(app)
        embedded_hashes[f"Payload/{app.name}/{executable.name}"] = sha256(executable)
        archive_path = stage / "unsigned.ipa"
        print("注入完成，打包并校验 IPA…", flush=True)
        pack(app.parent, archive_path)
        with zipfile.ZipFile(archive_path) as archive:
            import hashlib
            # ditto writes UTF-8 names without setting ZIP's UTF-8 flag, and macOS
            # may decompose Unicode filenames. Match the names actually archived.
            members = {}
            for entry in archive.infolist():
                name = entry.filename
                if not entry.flag_bits & 0x800:
                    name = name.encode('cp437').decode('utf-8')
                members[unicodedata.normalize('NFC', name)] = entry
            for name, expected in embedded_hashes.items():
                digest = hashlib.sha256()
                with archive.open(members[unicodedata.normalize('NFC', name)]) as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        digest.update(block)
                if digest.hexdigest() != expected:
                    raise ValueError(f"打包后文件校验失败：{name}")
        return publish(archive_path, output, {"step": "package", "input": str(source),
                       "bundle_id": info["CFBundleIdentifier"], "original_executable_sha256": source_hash,
                       "embedded_sha256": embedded_hashes, "patches": patches,
                       "dependency_check": dependency_check,
                       "requires_resigning": True, "device_tested": False})

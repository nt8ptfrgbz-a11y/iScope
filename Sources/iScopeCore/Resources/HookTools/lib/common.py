"""Shared filesystem, archive and command helpers (Python 3.10+)."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import subprocess
import signal
import zipfile


CHILDREN = set()


def signal_group(process, signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        # macOS can report EPERM when the final member is already exiting.
        try: process.send_signal(signum)
        except (ProcessLookupError, PermissionError): pass


def stop_children():
    for process in tuple(CHILDREN):
        if process.poll() is None:
            signal_group(process, signal.SIGTERM)


def managed_process(args, **kwargs):
    process = subprocess.Popen([str(arg) for arg in args], start_new_session=True, **kwargs)
    CHILDREN.add(process)
    return process


def finish_process(process):
    try:
        if process.poll() is None:
            signal_group(process, signal.SIGTERM)
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                signal_group(process, signal.SIGKILL)
                process.wait(timeout=1)
    except ProcessLookupError:
        pass
    finally:
        CHILDREN.discard(process)


def run(*args):
    process = managed_process(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, stderr = process.communicate()
    finally:
        finish_process(process)
    if process.returncode:
        detail = (stderr or stdout).decode(errors="replace").strip()
        raise RuntimeError(f"{args[0]} 执行失败：\n{detail}")
    return stdout


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def path_arg(value):
    return Path(value).expanduser().resolve()


def read_plist(path):
    result = plistlib.loads(Path(path).read_bytes())
    if not isinstance(result, dict):
        raise ValueError(f"plist 必须是字典：{path}")
    return result


def write_plist(path, value):
    Path(path).write_bytes(plistlib.dumps(value, fmt=plistlib.FMT_BINARY))


def app_info(app):
    info = read_plist(app / "Info.plist")
    name = info.get("CFBundleExecutable")
    if (not isinstance(name, str) or not name or name in (".", "..")
            or Path(name).name != name or not (app / name).is_file()):
        raise ValueError(f"无效的 CFBundleExecutable：{app}")
    if not info.get("CFBundleIdentifier"):
        raise ValueError(f"缺少 CFBundleIdentifier：{app}")
    return info


def check_links(root):
    root = root.resolve()
    for path in root.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(root):
            raise ValueError(f"符号链接指向包外：{path}")


def validate_archive(archive):
    """Resolve the complete link graph before ditto can write any member."""
    entries = archive.infolist()
    if len(entries) > 500000 or sum(entry.file_size for entry in entries) > 64 * 1024**3:
        raise ValueError('IPA 文件数量或展开大小超过限制（500,000 项 / 64 GB）')
    links, members, seen = {}, [], set()
    for entry in archive.infolist():
        if entry.orig_filename != entry.filename or "\\" in entry.filename:
            raise ValueError("IPA 包含无效的归档路径")
        # ditto reads local headers; reject disagreement with the central directory.
        archive.fp.seek(entry.header_offset)
        header = archive.fp.read(30)
        import struct
        if len(header) != 30 or header[:4] != b"PK\x03\x04":
            raise ValueError("IPA 本地文件头无效")
        flags, name_length, extra_length = struct.unpack_from("<H", header, 6)[0], *struct.unpack_from("<HH", header, 26)
        name = archive.fp.read(name_length).decode("utf-8" if flags & 0x800 else "cp437")
        if name != entry.orig_filename or flags != entry.flag_bits:
            raise ValueError("IPA 本地文件头与中央目录不一致")
        path = PurePosixPath(entry.filename)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            raise ValueError(f"IPA 包含不安全路径：{entry.filename}")
        parts = path.parts
        if parts in seen:
            raise ValueError(f"IPA 包含重复路径：{entry.filename}")
        seen.add(parts)
        members.append(parts)
        mode = entry.external_attr >> 16
        if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
            raise ValueError(f"IPA 包含特殊文件：{entry.filename}")
        if stat.S_ISLNK(mode):
            if entry.file_size > 4096:
                raise ValueError("IPA 符号链接过长")
            target = PurePosixPath(archive.read(entry).decode("utf-8"))
            if target.is_absolute() or not target.parts:
                raise ValueError("IPA 包含无效符号链接")
            links[parts] = target.parts

    def resolve(parts):
        pending, resolved, hops = list(parts), [], 0
        while pending:
            part = pending.pop(0)
            if part == "..":
                if not resolved:
                    raise ValueError("IPA 符号链接指向解压目录外")
                resolved.pop()
                continue
            if part == ".":
                continue
            resolved.append(part)
            key = tuple(resolved)
            if key in links:
                hops += 1
                if hops > 40:
                    raise ValueError("IPA 符号链接循环或层级过深")
                resolved.pop()
                pending = list(links[key]) + pending
        return resolved

    for parts in members:
        # No archive member may be written through a symlink ancestor.
        if any(parts[:i] in links for i in range(1, len(parts))):
            raise ValueError("IPA 含通过符号链接写入的成员")
        resolve(parts)


def extract_ipa(source, destination):
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as archive:
        validate_archive(archive)
        needed = sum(item.file_size for item in archive.infolist()) + 128 * 1024**2
        if shutil.disk_usage(destination).free < needed:
            raise ValueError(f"解压空间不足，至少需要 {needed // 1024**2} MB")
    run("ditto", "-x", "-k", source, destination)
    check_links(destination)
    apps = list((destination / "Payload").glob("*.app"))
    if len(apps) != 1 or apps[0].is_symlink() or not apps[0].is_dir():
        raise ValueError("Payload 内必须有且仅有一个主 App")
    check_links(apps[0])
    app_info(apps[0])
    return apps[0]


def stage_input(source, destination):
    if source.is_dir() and source.suffix == ".app":
        check_links(source)
        app_info(source)
        target = destination / "Payload" / source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        run("ditto", "--norsrc", source, target)
        return target
    if not source.is_file():
        raise ValueError(f"输入必须是 .app 目录或 IPA：{source}")
    return extract_ipa(source, destination)


def prepare_output(output, source=None):
    if source and (output == source or output.is_relative_to(source)):
        raise ValueError("输出不能覆盖输入，也不能位于输入 App 内")
    report = output.with_suffix(output.suffix + ".report.json")
    if output.exists() or report.exists():
        raise ValueError(f"输出已存在，请换一个文件名：{output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    return report


def publish(staged, output, report):
    report_path = output.with_suffix(output.suffix + ".report.json")
    report.update(output=str(output), output_sha256=sha256(staged))
    # Staging is on the same volume. link() publishes atomically and never replaces.
    os.link(staged, output)
    try:
        with report_path.open("x", encoding="utf-8") as stream:
            json.dump(report, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
    except BaseException:
        output.unlink()
        raise
    print(f"产物：{output}\n报告：{report_path}", flush=True)
    return output


def pack(payload, destination):
    run("ditto", "-c", "-k", "--norsrc", "--keepParent", payload, destination)
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip():
            raise ValueError("IPA ZIP 完整性校验失败")

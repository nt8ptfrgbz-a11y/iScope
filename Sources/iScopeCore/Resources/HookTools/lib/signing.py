"""Development, Ad Hoc and enterprise signing for a standalone main App."""
import datetime
import fnmatch
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
import zipfile

from common import (app_info, extract_ipa, pack, prepare_output, publish, read_plist,
                    run, sha256, validate_archive, write_plist)
from macho import inspect
from dependencies import check_dependencies


def permitted(value, allowance):
    if isinstance(value, str) and isinstance(allowance, str):
        return fnmatch.fnmatchcase(value, allowance)
    if isinstance(value, list) and isinstance(allowance, list):
        return all(any(permitted(item, allowed) for allowed in allowance) for item in value)
    if isinstance(value, dict) and isinstance(allowance, dict):
        return all(key in allowance and permitted(item, allowance[key]) for key, item in value.items())
    return type(value) is type(allowance) and value == allowance


def profile_entitlements(profile, bundle_id, device_udids=(), extra=None):
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        raise ValueError("Bundle ID 格式无效")
    expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
    if expires <= datetime.datetime.now(datetime.timezone.utc):
        raise ValueError("描述文件已过期")
    if "iOS" not in profile.get("Platform", []):
        raise ValueError("需要 iOS 描述文件")
    allowed = profile["Entitlements"]
    development = bool(allowed.get("get-task-allow"))
    enterprise = bool(profile.get("ProvisionsAllDevices"))
    devices = profile.get("ProvisionedDevices", [])
    if not devices and not enterprise:
        raise ValueError("App Store/TestFlight 描述文件不能用于此处直接安装，请选 Development、Ad Hoc 或企业描述文件")
    if not enterprise and any(udid.casefold() not in {item.casefold() for item in devices} for udid in device_udids):
        raise ValueError("指定设备 UDID 不在描述文件中")
    pattern = allowed.get("application-identifier", "")
    if "." not in pattern:
        raise ValueError("描述文件缺少 application-identifier")
    app_id = pattern.split(".", 1)[0] + "." + bundle_id
    if not fnmatch.fnmatchcase(app_id, pattern):
        raise ValueError(f"描述文件允许 {pattern}，不匹配 {bundle_id}")
    team = allowed.get("com.apple.developer.team-identifier")
    if not team:
        raise ValueError("描述文件缺少 Team ID")
    values = {"application-identifier": app_id, "com.apple.developer.team-identifier": team,
              "get-task-allow": development, "keychain-access-groups": [app_id]}
    for key, value in (extra or {}).items():
        if key in values and key != "keychain-access-groups" and value != values[key]:
            raise ValueError(f"不能覆盖签名身份权限：{key}")
        values[key] = value
    for key, value in values.items():
        if key == "get-task-allow" and value is False and key not in allowed:
            continue
        if key not in allowed or not permitted(value, allowed[key]):
            raise ValueError(f"描述文件不允许该 entitlement：{key}")
        if isinstance(value, str) and "*" in value or isinstance(value, list) and any(isinstance(x, str) and "*" in x for x in value):
            raise ValueError(f"实际签名 entitlement 必须为具体值：{key}")
    return values, "development" if development else "enterprise" if enterprise else "ad-hoc"


def input_bundle_id(source):
    """Read the main bundle identifier without extracting a large IPA."""
    if source.is_dir() and source.suffix == ".app":
        return app_info(source)["CFBundleIdentifier"]
    with zipfile.ZipFile(source) as archive:
        validate_archive(archive)
        names = [entry.filename for entry in archive.infolist()
                 if len(Path(entry.filename).parts) == 3
                 and Path(entry.filename).parts[0] == "Payload"
                 and Path(entry.filename).parts[1].endswith(".app")
                 and Path(entry.filename).parts[2] == "Info.plist"]
        if len(names) != 1:
            raise ValueError("IPA 中必须有且仅有一个主 App 的 Info.plist")
        info = plistlib.loads(archive.read(names[0]))
    bundle_id = info.get("CFBundleIdentifier") if isinstance(info, dict) else None
    if not isinstance(bundle_id, str) or not bundle_id:
        raise ValueError("IPA 主 App 缺少有效的 CFBundleIdentifier")
    return bundle_id


def default_resign_output(source):
    """Keep the input filename and avoid replacing existing IPA/report pairs."""
    output = source.with_name(source.stem + "-resign.ipa")
    counter = 2
    while output.exists() or output.with_suffix(".ipa.report.json").exists():
        output = source.with_name(f"{source.stem}-resign-{counter}.ipa")
        counter += 1
    return output


def default_resign_bundle_id(original):
    """Use a separate app ID; re-signing an existing copy keeps that ID stable."""
    suffix = ".regisn"
    return original if original.endswith(suffix) else original + suffix


def local_profile_paths(search_dirs=()):
    tool_root = Path(__file__).resolve().parents[1]
    roots = [Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles",
             Path.home() / "Library/MobileDevice/Provisioning Profiles",
             tool_root / "profiles", tool_root, Path.cwd(), *search_dirs]
    return sorted({path.resolve() for root in roots for path in Path(root).glob("*.mobileprovision")
                   if path.is_file()})


def signing_assets(profile_path, bundle_id, identity=None, device_udids=(), extra_path=None,
                   *, search_dirs=()):
    """Choose a valid local profile/certificate pair; explicit overrides stay strict."""
    if identity and not re.fullmatch(r"[0-9A-Fa-f]{40}", identity):
        raise ValueError("--identity 使用 security find-identity 输出的 40 位 SHA-1")
    available = run("security", "find-identity", "-v", "-p", "codesigning").decode()
    identities = [(fingerprint.upper(), name) for fingerprint, name in re.findall(
        r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"\n]+)"', available, re.MULTILINE)]
    if identity:
        identities = [item for item in identities if item[0] == identity.upper()]
    if not identities:
        raise ValueError("未找到可用的本机签名证书及私钥（或 --identity 未匹配）。"
                         "请检查钥匙串是否解锁、终端是否有访问权限；可运行 security find-identity -v -p codesigning 查看。")
    paths = [profile_path] if profile_path else local_profile_paths(search_dirs)
    if not paths:
        raise ValueError(f"未找到本机描述文件。目标 Bundle ID {bundle_id} 需要允许该 ID 的描述文件（可为通配）。"
                         "请将 .mobileprovision 放到 IPA 同目录、工具的 profiles/ 或 Xcode 描述文件目录。")
    extra = read_plist(extra_path) if extra_path else None
    candidates, issues = [], []
    for path in paths:
        try:
            raw = path.read_bytes()
            profile = plistlib.loads(run("security", "cms", "-D", "-i", path))
            entitlements, kind = profile_entitlements(profile, bundle_id, device_udids, extra)
            permitted_ids = {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}
            matches = [(fingerprint, name) for fingerprint, name in identities if fingerprint in permitted_ids]
            if not matches:
                raise ValueError("没有与该描述文件匹配的本机证书及私钥")
        except (OSError, ValueError, RuntimeError, KeyError, TypeError) as error:
            if profile_path:
                raise ValueError(f"指定的描述文件不可用：{path}\n{error}") from error
            issues.append(f"{path.name}：{error}")
            continue
        # Prefer exact App IDs, then development (local testing), then longest
        # remaining profile lifetime. Fingerprint/path break ties reproducibly.
        pattern = profile["Entitlements"]["application-identifier"]
        expires = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc).timestamp()
        for fingerprint, name in matches:
            rank = ("*" in pattern, kind != "development", -expires, fingerprint, str(path))
            assets = {"profile": profile, "profile_bytes": raw, "identity": fingerprint,
                      "identity_name": name, "profile_path": str(path),
                      "entitlements": entitlements, "kind": kind}
            candidates.append((rank, assets))
    if not candidates:
        details = "\n- ".join(issues)
        raise ValueError(f"本机没有可用于 Bundle ID {bundle_id} 的有效描述文件/证书组合。"
                         "描述文件需要允许此目标 ID；只有证书不能替代描述文件。"
                         f"\n已检查 {len(paths)} 份描述文件：\n- {details}")
    assets = min(candidates, key=lambda item: item[0])[1]
    print(f"签名检查通过：{assets['kind']} / {assets['identity_name']}\n"
          f"证书 SHA-1：{assets['identity']}\n"
          f"描述文件：{assets['profile'].get('Name', '')}（{assets['profile_path']}）", flush=True)
    return assets


def rename_app(app, display_name):
    if display_name is None:
        return []
    if not display_name.strip() or any(ord(char) < 32 for char in display_name):
        raise ValueError("显示名称不能为空或含控制字符")
    info = read_plist(app / "Info.plist")
    info["CFBundleDisplayName"] = display_name
    write_plist(app / "Info.plist", info)
    paths = sorted(app.glob("*.lproj/InfoPlist.strings"))
    for path in paths:
        values = plistlib.loads(run("plutil", "-convert", "xml1", "-o", "-", path))
        values["CFBundleDisplayName"] = display_name
        write_plist(path, values)
    return [str(path.relative_to(app)) for path in paths]


def signing_targets(app):
    info = app_info(app)
    main_binary = (app / info["CFBundleExecutable"]).resolve()
    targets, found_main = set(), False
    for path in app.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        images = inspect(path)
        if not images:
            continue
        if any(any(image["cryptids"]) for image in images):
            raise ValueError(f"仍有加密 Mach-O：{path.relative_to(app)}")
        if path.resolve() == main_binary:
            if any(image["kind"] != 2 for image in images):
                raise ValueError("主程序不是 MH_EXECUTE")
            found_main = True
            continue
        target = path
        for parent in path.parents:
            if parent == app:
                break
            if parent.suffix in (".framework", ".bundle") and (parent / "Info.plist").is_file():
                executable = read_plist(parent / "Info.plist").get("CFBundleExecutable")
                if executable and (parent / executable).resolve() == path.resolve():
                    target = parent
                    break
        targets.add(target)
    if not found_main:
        raise ValueError("主程序不是有效的 Mach-O")
    return sorted(targets, key=lambda path: (-len(path.parts), str(path)))


def verify_signed(app, assets, work, display_name=None, localizations=()):
    run("codesign", "--verify", "--deep", "--strict", app)
    signed = plistlib.loads(run("codesign", "-d", "--entitlements", "-", "--xml", app))
    if signed != assets["entitlements"]:
        raise ValueError("已签名权限与配置不一致")
    prefix = work / "certificate-"
    run("codesign", "-d", f"--extract-certificates={prefix}", app)
    if hashlib.sha1((work / "certificate-0").read_bytes()).hexdigest().upper() != assets["identity"]:
        raise ValueError("实际签名证书不匹配")
    if (app / "embedded.mobileprovision").read_bytes() != assets["profile_bytes"]:
        raise ValueError("打包后的描述文件不匹配")
    if display_name is not None:
        for path in (app / "Info.plist", *(app / item for item in localizations)):
            if read_plist(path).get("CFBundleDisplayName") != display_name:
                raise ValueError("打包后的桌面名称不匹配")


def handle_extensions(app, strip_extensions=True):
    """The default single-profile workflow produces a main-App-only copy."""
    roots = ("PlugIns", "Watch", "WatchKitSupport", "WatchKitSupport2", "AppClips")
    nested = sorted(path for path in app.rglob("*")
                    if path.is_dir() and path.suffix in (".app", ".appex", ".xpc"))
    remaining = [path for path in nested
                 if not strip_extensions or path.relative_to(app).parts[0] not in roots]
    if remaining:
        names = ", ".join(str(path.relative_to(app)) for path in remaining)
        if strip_extensions:
            raise ValueError(f"发现非标准独立签名组件：{names}。需要逐组件签名，无法纳入主 App 单描述文件流程。")
        raise ValueError(f"选择了保留扩展，但以下组件需要各自的描述文件和权限：{names}。"
                         "当前工具支持主 App 重签；去掉 --keep-extensions 即可自动移除标准扩展。")
    removed = []
    if strip_extensions:
        for name in roots:
            path = app / name
            if path.exists() or path.is_symlink():
                removed.append(name)
                for component in nested:
                    if component.is_relative_to(path):
                        print(f"移除扩展（副本）：{component.relative_to(app)}", flush=True)
                print(f"移除扩展目录（副本）：{name}", flush=True)
                if path.is_symlink() or not path.is_dir():
                    path.unlink()
                else:
                    shutil.rmtree(path)
    return removed


def resign_ipa(source, output, assets, bundle_id, *, display_name=None,
               strip_extensions=True, isolate_url_schemes=False):
    prepare_output(output, source)
    source_hash = sha256(source)
    with tempfile.TemporaryDirectory(prefix=".resign-", dir=output.parent) as directory:
        work = Path(directory)
        unpacked = work / "unpacked"
        app = extract_ipa(source, unpacked)
        info = app_info(app)
        original_bundle_id = info["CFBundleIdentifier"]
        removed = handle_extensions(app, strip_extensions)
        dependency_check = check_dependencies(app)
        targets = signing_targets(app)
        for path in sorted(app.rglob("SC_Info"), key=lambda path: -len(path.parts)):
            if path.is_symlink() or path.is_file():
                path.unlink()
            else:
                shutil.rmtree(path)
            removed.append(str(path.relative_to(app)))
        # Discard obsolete seals before creating new inside-out signatures.
        for path in sorted(app.rglob("_CodeSignature"), key=lambda path: -len(path.parts)):
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
        info["CFBundleIdentifier"] = bundle_id
        if isolate_url_schemes:
            info["CFBundleURLTypes"] = [{"CFBundleURLName": bundle_id,
                                        "CFBundleURLSchemes": [bundle_id.replace(".", "-")]}]
        write_plist(app / "Info.plist", info)
        localizations = rename_app(app, display_name)
        (app / "embedded.mobileprovision").write_bytes(assets["profile_bytes"])
        entitlements_path = work / "entitlements.plist"
        # codesign --entitlements requires a textual XML plist on this macOS;
        # the binary plist format used for bundle metadata is not accepted.
        entitlements_path.write_bytes(plistlib.dumps(assets["entitlements"], fmt=plistlib.FMT_XML))
        for target in targets:
            print(f"签名：{target.relative_to(app)}", flush=True)
            run("codesign", "--force", "--sign", assets["identity"], "--timestamp=none", target)
        print("签名主 App…", flush=True)
        run("codesign", "--force", "--sign", assets["identity"], "--timestamp=none",
            "--entitlements", entitlements_path, "--generate-entitlement-der", app)
        verify_signed(app, assets, work, display_name, localizations)
        archive_path = work / "signed.ipa"
        pack(app.parent, archive_path)
        shutil.rmtree(unpacked)
        print("重新解压最终 IPA，复验签名、权限和描述文件…", flush=True)
        restored = extract_ipa(archive_path, work / "restored")
        verify_signed(restored, assets, work, display_name, localizations)
        profile = assets["profile"]
        return publish(archive_path, output, {"step": "resign", "input": str(source),
                       "input_sha256": source_hash, "bundle_id": bundle_id,
                       "original_bundle_id": original_bundle_id, "display_name": display_name,
                       "distribution": assets["kind"], "identity_sha1": assets["identity"],
                       "profile_path": assets.get("profile_path"),
                       "profile_name": profile.get("Name"), "profile_uuid": profile.get("UUID"),
                       "profile_expires": profile["ExpirationDate"].isoformat(),
                       "entitlements": assets["entitlements"], "removed_components": removed,
                       "url_schemes_isolated": isolate_url_schemes,
                       "nested_code_signed": len(targets), "packaged_signature_verified": True,
                       "dependency_check": dependency_check,
                       "device_tested": False})

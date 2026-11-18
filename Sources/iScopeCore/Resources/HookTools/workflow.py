#!/usr/bin/env python3
"""iScope workflow protocol v1. All subprocess arguments are passed without a shell."""
import argparse
import contextlib
import datetime
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import traceback
import uuid
import zipfile

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'lib'))
import common
from common import app_info, check_links, extract_ipa, run, validate_archive
from devices import connected_ios_devices
from macho import check_device_images, inspect
from package import package_ipa
from signing import default_resign_bundle_id, profile_entitlements, resign_ipa, signing_assets
from dependencies import check_dependencies

WIRE = sys.stdout
LOG = None
CURRENT_STAGE = 'preflight'


class Cancelled(BaseException):
    pass


def emit(kind, **values):
    document = {'version': 1, 'type': kind, **values}
    WIRE.write(json.dumps(document, ensure_ascii=False) + '\n')
    WIRE.flush()


def log(message):
    message = str(message).rstrip()
    if LOG:
        LOG.write(message + '\n'); LOG.flush()
    if message:
        emit('log', message=message[:16000])


class LogWriter(io.TextIOBase):
    def __init__(self): self.pending = ''
    def write(self, value):
        self.pending += value
        while '\n' in self.pending:
            line, self.pending = self.pending.split('\n', 1); log(line)
        if len(self.pending) > 16000:
            log(self.pending); self.pending = ''
        return len(value)
    def flush(self):
        if self.pending: log(self.pending); self.pending = ''


def stage(name, state, message=''):
    global CURRENT_STAGE
    CURRENT_STAGE = name
    emit('stage', stage=name, state=state, message=message)
    if message: log(message)


def stream_command(arguments):
    process = common.managed_process(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
    tail = []
    try:
        for line in process.stdout:
            log(line)
            tail = (tail + [line.rstrip()])[-25:]
        status = process.wait()
        if status:
            raise RuntimeError('编译失败：\n' + '\n'.join(tail))
    finally:
        if process.stdout: process.stdout.close()
        common.finish_process(process)


def query_devices():
    with tempfile.TemporaryDirectory(prefix='iScope-devices-') as directory:
        path = Path(directory) / 'devices.json'
        run('/usr/bin/xcrun', 'devicectl', 'list', 'devices', '--timeout', '15', '--quiet', '--json-output', path)
        return connected_ios_devices(json.loads(path.read_text()))


def select_device(requested):
    devices = query_devices()
    matches = [device for device in devices if requested.casefold() in
               {device['identifier'].casefold(), device['udid'].casefold(), device['name'].casefold()}] if requested else devices
    if len(matches) != 1:
        if not matches:
            raise ValueError('未找到所选的已连接真机。请连接并解锁 iPhone/iPad、信任这台 Mac，然后刷新设备。')
        raise ValueError('检测到多台真机，请在设备列表中明确选择一台。')
    return matches[0]


def probe():
    result = {'pythonVersion': sys.version.split()[0], 'xcodeVersion': '', 'sdk': '', 'identities': [], 'devices': [], 'warnings': []}
    try:
        result['xcodeVersion'] = run('/usr/bin/xcodebuild', '-version').decode().strip()
        result['sdk'] = run('/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-path').decode().strip()
    except Exception as error: result['warnings'].append(str(error))
    try:
        identities = run('/usr/bin/security', 'find-identity', '-v', '-p', 'codesigning').decode()
        result['identities'] = [{'fingerprint': sha.upper(), 'name': name} for sha, name in
                                re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"\n]+)"', identities, re.MULTILINE)]
    except Exception as error: result['warnings'].append(str(error))
    try: result['devices'] = query_devices()
    except Exception as error: result['warnings'].append(str(error))
    emit('environment', environment=result)


def source_metadata(source):
    if source.is_dir() and source.suffix == '.app':
        check_links(source)
        info = app_info(source)
        images = inspect(source / info['CFBundleExecutable'])
    else:
        with zipfile.ZipFile(source) as archive:
            validate_archive(archive)
            entries = [entry.filename for entry in archive.infolist()
                       if len(Path(entry.filename).parts) == 3 and entry.filename.startswith('Payload/')
                       and Path(entry.filename).parts[1].endswith('.app') and Path(entry.filename).name == 'Info.plist']
            if len(entries) != 1: raise ValueError('输入 IPA 必须包含唯一的主 App。')
            info = plistlib.loads(archive.read(entries[0]))
            executable = info.get('CFBundleExecutable')
            if not isinstance(executable, str) or Path(executable).name != executable or executable in ('.', '..'):
                raise ValueError('主 App 的 CFBundleExecutable 无效。')
            name = str(Path(entries[0]).parent / executable)
            with tempfile.TemporaryDirectory(prefix='iScope-main-') as directory:
                path = Path(directory) / 'Main'
                with archive.open(name) as stream, path.open('wb') as target: shutil.copyfileobj(stream, target)
                images = inspect(path)
    check_device_images(images, 2)
    architectures = []
    for image in images:
        subtype = image['subtype'] & 0xFFFFFF
        if subtype not in (0, 2): raise ValueError('主程序包含当前不支持的 ARM64 子架构。')
        architecture = 'arm64e' if subtype == 2 else 'arm64'
        if architecture not in architectures: architectures.append(architecture)
    identifier = info.get('CFBundleIdentifier')
    if not isinstance(identifier, str) or not identifier: raise ValueError('主 App 缺少 Bundle ID。')
    return info, architectures


def snapshot_project(project, destination, output_root, final_id):
    parent = project.parent
    manifest_path = parent / 'HookTargets.json'
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('generator') != 'iScope': raise ValueError('请选择 iScope 生成的 Hook 工程（需要 HookTargets.json）。')
    original_id = manifest['targetBundleIdentifier']
    excluded = {'.git', 'build', 'DerivedData', 'iScopeOutput', '.build', 'xcuserdata', '__pycache__'}
    if output_root == parent: raise ValueError('输出目录不能直接使用工程根目录，请选择工程内的 iScopeOutput 子目录或其他目录。')
    if output_root.is_relative_to(parent): excluded.add(output_root.relative_to(parent).parts[0])
    def ignore(folder, names):
        return [name for name in names if name in excluded or name.endswith('.ipa')]
    shutil.copytree(parent, destination, symlinks=True, ignore=ignore)
    check_links(destination)
    source = destination / 'Hooks.m'
    text = source.read_text()
    if final_id != original_id:
        old = 'if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@' + json.dumps(original_id) + ']) return;'
        new = 'if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@' + json.dumps(final_id) + ']) return;'
        if text.count(old) != 1:
            raise ValueError('无法自动适配工程的 Bundle ID 过滤条件。请保留 iScope 生成的过滤语句，或重新生成工程。')
        source.write_text(text.replace(old, new))
        manifest['targetBundleIdentifier'] = final_id
        (destination / 'HookTargets.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        log('已在构建副本中适配 Hook 的 Bundle ID：' + final_id)
    return destination / project.name


def install_signed(ipa, requested_device, result):
    stage('install', 'running', '验证已签名产物，准备安装到真机…')
    device = select_device(requested_device)
    with tempfile.TemporaryDirectory(prefix='iScope-install-') as directory:
        work = Path(directory)
        app = extract_ipa(ipa, work / 'unpacked')
        info = app_info(app)
        profile_path = app / 'embedded.mobileprovision'
        if not profile_path.is_file(): raise ValueError('IPA 缺少 embedded.mobileprovision，请先重签。')
        profile = plistlib.loads(run('/usr/bin/security', 'cms', '-D', '-i', profile_path))
        profile_entitlements(profile, info['CFBundleIdentifier'], [device['udid']])
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
        check_dependencies(app)
        result.update(deviceIdentifier=device['identifier'], deviceName=device['name'],
                      signatureVerified=True, bundleIdentifier=info['CFBundleIdentifier'])
        log('安装到 ' + device['name'] + '，请保持设备解锁…')
        run('/usr/bin/xcrun', 'devicectl', 'device', 'install', 'app', '--device', device['identifier'],
            '--timeout', '300', '--json-output', work / 'install.json', app)
        document = json.loads((work / 'install.json').read_text())
        if document.get('info', {}).get('outcome') != 'success': raise ValueError('Xcode 未确认安装成功，请查看设备状态和日志。')
    result.update(installed=True, bundleIdentifier=info['CFBundleIdentifier'])
    stage('install', 'done', '安装完成。可在设备上启动 App 验证 Hook。')


def validate_request(request):
    if not isinstance(request, dict): raise ValueError('工作流请求必须是 JSON 对象。')
    for key in ('target', 'projectPath', 'inputPath', 'outputDirectory', 'bundleIdentifier', 'profilePath',
                'identitySHA1', 'entitlementsPath', 'displayName', 'deviceIdentifier'):
        value = request.get(key, '')
        if not isinstance(value, str) or '\x00' in value or len(value) > 16384:
            raise ValueError('工作流参数无效：' + key)
    if not request.get('outputDirectory', '').strip(): raise ValueError('请选择输出目录。')
    for key in ('stripExtensions', 'isolateURLSchemes'):
        if key in request and type(request[key]) is not bool: raise ValueError('工作流开关无效：' + key)
    search = request.get('profileSearchDirectories', [])
    if not isinstance(search, list) or len(search) > 64 or any(not isinstance(p, str) or '\x00' in p for p in search):
        raise ValueError('描述文件搜索目录无效。')


def execute(request):
    global LOG
    validate_request(request)
    mode = request.get('target')
    if mode not in ('build', 'package', 'sign', 'install', 'installExisting'): raise ValueError('未知执行目标。')
    root = Path(request['outputDirectory']).expanduser().resolve()
    if request.get('projectPath') and root == Path(request['projectPath']).expanduser().resolve().parent:
        raise ValueError('请选择工程内的 iScopeOutput 子目录或其他输出目录。')
    if request.get('inputPath'):
        input_path = Path(request['inputPath']).expanduser().resolve()
        if root == input_path or (input_path.is_dir() and root.is_relative_to(input_path)):
            raise ValueError('输出目录不能位于输入 App 内。')
    root.mkdir(parents=True, exist_ok=True)
    directory = root / (datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:8])
    directory.mkdir()
    LOG = (directory / 'workflow.log').open('w', encoding='utf-8', buffering=1)
    result = {'runDirectory': str(directory), 'dylib': None, 'unsignedIPA': None, 'signedIPA': None,
              'installed': False, 'signatureVerified': False, 'bundleIdentifier': '',
              'deviceIdentifier': None, 'deviceName': None, 'removedComponents': []}
    (directory / 'request.json').write_text(json.dumps(request, ensure_ascii=False, indent=2))
    def artifact():
        temporary = directory / '.result.json'
        temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2))
        temporary.replace(directory / 'result.json')
        emit('artifact', result=result)
    artifact()
    try:
        stage('preflight', 'running', '检查工程、输入、编译工具与签名材料…')
        source = Path(request['inputPath']).expanduser().resolve() if request.get('inputPath', '').strip() else None
        if mode == 'installExisting':
            if source is None or not source.is_file(): raise ValueError('待安装 IPA 不存在。')
            result['signedIPA'] = str(source)
            stage('preflight', 'done', '使用已生成的签名 IPA，跳过编译、注入和重签。')
            for item in ('build', 'package', 'sign'): stage(item, 'skipped')
            install_signed(source, request.get('deviceIdentifier', ''), result)
            result['signatureVerified'] = True
            artifact(); emit('complete', result=result); return
        project = Path(request['projectPath']).expanduser().resolve()
        if project.suffix != '.xcodeproj' or not project.is_dir(): raise ValueError('请选择有效的 .xcodeproj 工程。')
        manifest = json.loads((project.parent / 'HookTargets.json').read_text())
        if manifest.get('generator') != 'iScope': raise ValueError('请选择 iScope 生成的 Hook 工程。')
        original_id = manifest['targetBundleIdentifier']
        if source is None and mode != 'build': raise ValueError('请选择原始 IPA 或 .app。')
        if source is not None and not source.exists(): raise ValueError('原始 IPA 或 .app 不存在。')
        info, architectures = ({'CFBundleIdentifier': original_id}, ['arm64']) if source is None else source_metadata(source)
        if info['CFBundleIdentifier'] != original_id:
            raise ValueError('输入 App 的 Bundle ID 与 Hook 工程目标不符，请选择该工程对应的原始 IPA。')
        default_id = info['CFBundleIdentifier'] if mode in ('build', 'package') else default_resign_bundle_id(info['CFBundleIdentifier'])
        bundle_id = default_id if mode in ('build', 'package') else request.get('bundleIdentifier', '').strip() or default_id
        if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle_id): raise ValueError('目标 Bundle ID 无效。')
        result['bundleIdentifier'] = bundle_id
        run('/usr/bin/xcrun', '--sdk', 'iphoneos', '--show-sdk-path')
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,79}', project.stem): raise ValueError('当前流程支持 iScope 生成的工程名。')
        assets = None
        device = select_device(request.get('deviceIdentifier', '')) if mode == 'install' else None
        if device: result.update(deviceIdentifier=device['identifier'], deviceName=device['name'])
        if mode in ('sign', 'install'):
            profile = Path(request['profilePath']).expanduser().resolve() if request.get('profilePath') else None
            extra = Path(request['entitlementsPath']).expanduser().resolve() if request.get('entitlementsPath') else None
            search = [source.parent, project.parent, *[Path(value).expanduser() for value in request.get('profileSearchDirectories', [])]]
            assets = signing_assets(profile, bundle_id, request.get('identitySHA1') or None,
                                    [device['udid']] if device else [], extra, search_dirs=search)
        stage('preflight', 'done', '检查通过 · ' + ' / '.join(architectures) + ' · ' + bundle_id)
        stage('build', 'running', '正在使用 Xcode 编译 iOS 动态库…')
        snapshot = snapshot_project(project, directory / 'SourceSnapshot', root, bundle_id)
        products = directory / 'Products'
        stream_command(['/usr/bin/xcodebuild', '-project', snapshot, '-scheme', project.stem, '-configuration', 'Release',
                        '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS', '-derivedDataPath', directory / 'DerivedData',
                        'ARCHS=' + ' '.join(architectures), 'ONLY_ACTIVE_ARCH=NO', 'EXCLUDED_ARCHS=', 'CODE_SIGNING_ALLOWED=NO',
                        'CONFIGURATION_BUILD_DIR=' + str(products), 'build'])
        dylib = products / (project.stem + '.dylib')
        check_device_images(inspect(dylib), 6)
        result['dylib'] = str(dylib); artifact()
        stage('build', 'done', '动态库编译完成。')
        if mode != 'build':
            stage('package', 'running', '复制 App、注入 dylib、检查依赖并打包…')
            unsigned = package_ipa(source, [dylib], directory / (project.stem + '-unsigned.ipa'))
            result['unsignedIPA'] = str(unsigned); artifact()
            stage('package', 'done', '注入和打包校验完成。')
        else: stage('package', 'skipped')
        if assets:
            stage('sign', 'running', '签名嵌套代码和主 App，复验最终 IPA…')
            signed = resign_ipa(Path(result['unsignedIPA']), directory / (project.stem + '-signed.ipa'), assets, bundle_id,
                                display_name=request.get('displayName') or None,
                                strip_extensions=request.get('stripExtensions', True), isolate_url_schemes=request.get('isolateURLSchemes', False))
            report = json.loads(signed.with_suffix('.ipa.report.json').read_text())
            result.update(signedIPA=str(signed), signatureVerified=report['packaged_signature_verified'], removedComponents=report['removed_components'])
            artifact(); stage('sign', 'done', '最终 IPA 签名、权限、证书和描述文件复验通过。')
        else: stage('sign', 'skipped')
        if mode == 'install':
            install_signed(Path(result['signedIPA']), device['identifier'], result)
        else: stage('install', 'skipped')
        artifact(); emit('complete', result=result)
    except BaseException:
        artifact()
        raise
    finally:
        LOG.flush()


def cancel(signum, frame):
    common.stop_children()
    raise Cancelled()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=('probe', 'run'))
    parser.add_argument('--request', type=Path)
    args = parser.parse_args()
    if sys.version_info < (3, 10): raise ValueError('需要 Python 3.10 或更高版本。')
    if os.getpgrp() != os.getpid(): os.setpgrp()
    signal.signal(signal.SIGTERM, cancel); signal.signal(signal.SIGINT, cancel)
    writer = LogWriter()
    try:
        with contextlib.redirect_stdout(writer):
            if args.command == 'probe': probe()
            else:
                if not args.request: raise ValueError('缺少工作流请求。')
                if args.request.stat().st_size > 1024 * 1024: raise ValueError('工作流请求超过大小限制。')
                request = json.loads(args.request.read_text())
                execute(request)
        writer.flush()
    except Cancelled:
        emit('stage', stage=CURRENT_STAGE, state='cancelled', message='已取消，完成的中间产物已保留。')
        sys.exit(130)
    except Exception as error:
        if LOG: LOG.write(traceback.format_exc()); LOG.flush()
        emit('stage', stage=CURRENT_STAGE, state='failed', message=str(error))
        emit('error', message=str(error))
        sys.exit(1)
    finally:
        common.stop_children()
        for process in tuple(common.CHILDREN): common.finish_process(process)
        if LOG: LOG.close()


if __name__ == '__main__': main()

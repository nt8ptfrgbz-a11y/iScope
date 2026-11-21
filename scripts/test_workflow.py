#!/usr/bin/env python3
"""Backend regressions. Uses disposable fixtures and mocked signing/install operations."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1] / 'Sources/iScopeCore/Resources/HookTools'
sys.path.insert(0, str(ROOT))
import workflow as w


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='iScope backend 中文 ')
        self.work = Path(self.temporary.name).resolve()
        self.parent = self.work / 'CounterHook'
        self.project = self.parent / 'CounterHook.xcodeproj'
        self.project.mkdir(parents=True)
        self.original = 'if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.example.counter"]) return;'
        (self.parent / 'Hooks.m').write_text(self.original)
        (self.parent / 'HookTargets.json').write_text(json.dumps({'generator': 'iScope', 'targetBundleIdentifier': 'com.example.counter'}))
        self.ipa = self.work / 'original.ipa'; self.ipa.write_bytes(b'original content')
        self.request = {'target': 'sign', 'projectPath': str(self.project), 'inputPath': str(self.ipa),
                        'outputDirectory': str(self.parent / 'iScopeOutput')}
        self.events = []
        self.emit = patch.object(w, 'emit', lambda kind, **values: self.events.append({'type': kind, **values}))
        self.emit.start()
        w.LOG = None

    def tearDown(self):
        if w.LOG: w.LOG.close(); w.LOG = None
        self.emit.stop(); self.temporary.cleanup()

    def test_snapshot_adapts_only_copy_and_excludes_outputs(self):
        output = self.parent / 'iScopeOutput'; output.mkdir()
        (output / 'huge.ipa').write_bytes(b'existing')
        destination = output / 'run/SourceSnapshot'
        destination.parent.mkdir()
        copied = w.snapshot_project(self.project, destination, output, 'com.example.counter.regisn')
        self.assertEqual(copied.name, self.project.name)
        self.assertIn('com.example.counter.regisn', (destination / 'Hooks.m').read_text())
        self.assertEqual((self.parent / 'Hooks.m').read_text(), self.original)
        self.assertFalse((destination / 'iScopeOutput').exists())
        with self.assertRaises(ValueError):
            w.snapshot_project(self.project, self.work / 'bad', self.parent, 'com.example.counter.regisn')

    def test_changed_filter_fails_explicitly(self):
        (self.parent / 'Hooks.m').write_text('// user removed the generated filter')
        with self.assertRaisesRegex(ValueError, '过滤条件'):
            w.snapshot_project(self.project, self.work / 'snapshot', self.work / 'output', 'com.example.counter.regisn')

    @contextlib.contextmanager
    def mocked_pipeline(self):
        def package(source, dylibs, output):
            output.write_bytes(b'injected'); return output
        def resign(source, output, assets, bundle_id, **kwargs):
            output.write_bytes(b'signed')
            output.with_suffix('.ipa.report.json').write_text(json.dumps({'packaged_signature_verified': True, 'removed_components': ['PlugIns']}))
            return output
        with contextlib.ExitStack() as stack:
            for name, value in {
                'source_metadata': lambda source: ({'CFBundleIdentifier': 'com.example.counter'}, ['arm64']),
                'run': lambda *args: b'', 'signing_assets': lambda *args, **kwargs: {'identity': 'test'},
                'stream_command': lambda args: None, 'inspect': lambda path: [],
                'check_device_images': lambda images, kind: None,
                'package_ipa': package, 'resign_ipa': resign,
                'select_device': lambda requested: {'identifier': 'device', 'udid': 'udid', 'name': 'Test iPhone'},
            }.items(): stack.enter_context(patch.object(w, name, value))
            yield

    def test_sign_stage_order_and_immutable_original(self):
        with self.mocked_pipeline(): w.execute(self.request)
        stages = [(e['stage'], e['state']) for e in self.events if e['type'] == 'stage']
        self.assertEqual(stages, [(s, state) for s in ('preflight', 'build', 'package', 'sign') for state in ('running', 'done')] + [('install', 'skipped')])
        result = self.events[-1]['result']
        self.assertTrue(result['signatureVerified'])
        self.assertFalse(result['installed'])
        self.assertEqual(result['bundleIdentifier'], 'com.example.counter.regisn')
        self.assertEqual(self.ipa.read_bytes(), b'original content')
        self.assertEqual((self.parent / 'Hooks.m').read_text(), self.original)

    def test_install_failure_preserves_signed_ipa(self):
        self.request['target'] = 'install'
        def fail(*args):
            w.stage('install', 'running'); raise ValueError('device locked')
        with self.mocked_pipeline(), patch.object(w, 'install_signed', fail):
            with self.assertRaisesRegex(ValueError, 'device locked'): w.execute(self.request)
        result = self.events[-1]['result']
        self.assertEqual(self.events[-1]['type'], 'artifact')
        self.assertTrue(result['signatureVerified'])
        self.assertEqual(Path(result['signedIPA']).read_bytes(), b'signed')
        self.assertFalse(result['installed'])
        saved = json.loads((Path(result['runDirectory']) / 'result.json').read_text())
        self.assertEqual(saved, result)

    def test_install_existing_skips_all_build_operations(self):
        self.request.update(target='installExisting', projectPath='')
        def install(source, device, result):
            w.stage('install', 'running'); result.update(installed=True, signatureVerified=True); w.stage('install', 'done')
        with patch.object(w, 'install_signed', install), patch.object(w, 'stream_command', side_effect=AssertionError('must not build')):
            w.execute(self.request)
        self.assertTrue(self.events[-1]['result']['installed'])
        self.assertEqual([e['stage'] for e in self.events if e.get('state') == 'skipped'], ['build', 'package', 'sign'])

    def test_build_without_input_uses_manifest(self):
        self.request.update(target='build', inputPath='', bundleIdentifier='com.custom.signed')
        with self.mocked_pipeline(), patch.object(w, 'source_metadata', side_effect=AssertionError('no IPA needed')):
            w.execute(self.request)
        self.assertEqual(self.events[-1]['result']['bundleIdentifier'], 'com.example.counter')

    def test_install_without_device_fails_before_build(self):
        self.request['target'] = 'install'
        with self.mocked_pipeline(), patch.object(w, 'select_device', side_effect=ValueError('未连接设备')), \
                patch.object(w, 'stream_command', side_effect=AssertionError('must not compile')):
            with self.assertRaisesRegex(ValueError, '未连接设备'): w.execute(self.request)
        self.assertIsNone(self.events[-1]['result']['dylib'])
        self.assertEqual(self.ipa.read_bytes(), b'original content')

    def test_standalone_build_uses_source_directory_without_project(self):
        hook = self.work / '自定义 hook.m'; hook.write_text('// source')
        (self.work / '自定义 hook.dylib').write_bytes(b'previous build')
        request = {'target': 'buildSource', 'sourcePath': str(hook), 'projectPath': '',
                   'outputDirectory': str(self.work / 'ignored'), 'architectures': ['arm64', 'arm64e']}
        def build(sources, output, **kwargs):
            self.assertEqual(sources, [hook])
            self.assertEqual(kwargs['architectures'], ['arm64', 'arm64e'])
            output.write_bytes(b'new build'); return output
        with patch.object(w, 'build_hook', build), patch.object(w, 'package_ipa', side_effect=AssertionError('must not inject')):
            w.execute(request)
        result = self.events[-1]['result']
        self.assertEqual(Path(result['dylib']), self.work / '自定义 hook-2.dylib')
        self.assertEqual((self.work / '自定义 hook.dylib').read_bytes(), b'previous build')
        self.assertEqual(hook.read_text(), '// source')
        self.assertEqual([e['stage'] for e in self.events if e.get('state') == 'skipped'], ['package', 'sign', 'install'])

    def test_standalone_package_uses_dylib_directory_and_external_ipa(self):
        folder = self.work / '动态库'; folder.mkdir()
        dylibs = [folder / 'One.dylib', folder / 'Two.dylib']
        for dylib in dylibs: dylib.write_bytes(b'library')
        (folder / 'original-unsigned.ipa.report.json').write_text('{}')
        request = {'target': 'packageExisting', 'inputPath': str(self.ipa), 'projectPath': '',
                   'dylibPaths': [str(path) for path in dylibs], 'outputDirectory': str(folder)}
        def package(source, selected, output):
            self.assertEqual(source, self.ipa); self.assertEqual(selected, dylibs)
            output.write_bytes(b'unsigned'); return output
        with patch.object(w, 'input_bundle_id', return_value='com.example.counter'), \
                patch.object(w, 'package_ipa', package), \
                patch.object(w, 'build_hook', side_effect=AssertionError('must not build')), \
                patch.object(w, 'resign_ipa', side_effect=AssertionError('must not sign')):
            w.execute(request)
        self.assertEqual(Path(self.events[-1]['result']['unsignedIPA']), folder / 'original-unsigned-2.ipa')
        self.assertEqual(self.ipa.read_bytes(), b'original content')
        self.assertEqual([e['stage'] for e in self.events if e.get('state') == 'skipped'], ['build', 'sign', 'install'])

    def test_standalone_sign_skips_build_and_package_and_preserves_input(self):
        (self.work / 'original-resign.ipa').write_bytes(b'previous signed')
        request = {'target': 'signExisting', 'inputPath': str(self.ipa), 'projectPath': '',
                   'outputDirectory': str(self.work / 'ignored')}
        with self.mocked_pipeline(), patch.object(w, 'input_bundle_id', return_value='com.example.counter'), \
                patch.object(w, 'package_ipa', side_effect=AssertionError('must not inject')), \
                patch.object(w, 'stream_command', side_effect=AssertionError('must not build')):
            w.execute(request)
        result = self.events[-1]['result']
        self.assertEqual(Path(result['signedIPA']), self.work / 'original-resign-2.ipa')
        self.assertEqual(result['bundleIdentifier'], 'com.example.counter.regisn')
        self.assertTrue(result['signatureVerified']); self.assertFalse(result['installed'])
        self.assertEqual(self.ipa.read_bytes(), b'original content')
        self.assertEqual((self.work / 'original-resign.ipa').read_bytes(), b'previous signed')
        self.assertEqual([e['stage'] for e in self.events if e.get('state') == 'skipped'], ['build', 'package', 'install'])

    def test_standalone_rejects_invalid_paths_and_records_failure(self):
        request = {'target': 'packageExisting', 'inputPath': str(self.ipa),
                   'outputDirectory': str(self.work), 'dylibPaths': []}
        with self.assertRaisesRegex(ValueError, '至少选择一个'):
            w.execute(request)
        self.assertEqual(self.events[-1]['type'], 'artifact')
        self.assertIsNone(self.events[-1]['result']['unsignedIPA'])

    def test_install_requires_explicit_devicectl_success(self):
        app = self.work / 'Test.app'; app.mkdir()
        (app / 'embedded.mobileprovision').write_bytes(b'profile')
        for outcome in ('failure', None, 'success'):
            def command(*args):
                if args[0] == '/usr/bin/security': return plistlib.dumps({})
                if args[0] == '/usr/bin/xcrun':
                    path = Path(args[args.index('--json-output') + 1])
                    path.write_text(json.dumps({'info': {'outcome': outcome}}))
                return b''
            result = {'installed': False, 'signatureVerified': False}
            with patch.object(w, 'select_device', return_value={'identifier': 'id', 'udid': 'udid', 'name': 'Test'}), \
                    patch.object(w, 'extract_ipa', return_value=app), patch.object(w, 'app_info', return_value={'CFBundleIdentifier': 'com.example.counter'}), \
                    patch.object(w, 'profile_entitlements'), patch.object(w, 'check_dependencies'), patch.object(w, 'run', command):
                if outcome == 'success': w.install_signed(self.ipa, '', result)
                else:
                    with self.assertRaisesRegex(ValueError, '未确认安装成功'): w.install_signed(self.ipa, '', result)
            self.assertEqual(result['installed'], outcome == 'success')

    def test_request_and_archive_validation(self):
        for bad in ([], {'outputDirectory': ''}, {'outputDirectory': 'ok', 'stripExtensions': 'yes'}, {'outputDirectory': 'ok', 'inputPath': 'x\0y'},
                    {'outputDirectory': 'ok', 'sourcePath': []}, {'outputDirectory': 'ok', 'dylibPaths': ['x\0y']},
                    {'outputDirectory': 'ok', 'architectures': ['x86_64']}):
            with self.assertRaises(ValueError): w.validate_request(bad)
        archive = self.work / 'mismatch.zip'
        with zipfile.ZipFile(archive, 'w') as target: target.writestr('safe.txt', 'data')
        contents = bytearray(archive.read_bytes()); contents[30:38] = b'evil.txt'; archive.write_bytes(contents)
        with zipfile.ZipFile(archive) as target:
            with self.assertRaisesRegex(ValueError, '不一致'): w.validate_archive(target)

    def test_device_filter_accepts_new_xcode_format(self):
        def device(name, connection='connected', reality='physical'):
            return {'identifier': name, 'properties': {'hardware': {'platform': 'iOS', 'reality': reality, 'udid': name},
                    'connection': {'state': connection, 'pairingState': 'paired'}, 'state': {'name': name, 'bootState': 'booted'}}}
        document = {'info': {'outcome': 'success'}, 'result': {'devices': [device('phone'), device('offline', 'disconnected'), device('simulator', reality='simulated')]}}
        self.assertEqual([d['name'] for d in w.connected_ios_devices(document)], ['phone'])

    def test_cancel_terminates_child_process_group(self):
        marker = self.work / 'child.pid'
        child = 'import os,time; from pathlib import Path; Path(' + repr(str(marker)) + ').write_text(str(os.getpid())); time.sleep(120)'
        code = 'import sys;sys.path.insert(0,' + repr(str(ROOT)) + ');import workflow as w;w.probe=lambda: w.run(sys.executable,"-c",' + repr(child) + ');sys.argv=["workflow","probe"];w.main()'
        process = subprocess.Popen([sys.executable, '-B', '-c', code], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 8
            while not marker.exists() and time.monotonic() < deadline: time.sleep(0.02)
            self.assertTrue(marker.exists(), 'child did not start')
            pid = int(marker.read_text())
            process.terminate(); stdout, stderr = process.communicate(timeout=8)
            self.assertEqual(process.returncode, 130, stdout.decode() + stderr.decode())
            self.assertIn(b'cancelled', stdout)
            with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
        finally:
            if process.poll() is None: process.kill(); process.communicate()


if __name__ == '__main__': unittest.main()

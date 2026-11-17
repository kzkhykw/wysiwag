#!/usr/bin/env python3
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parent


class VerifyCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='wysiwag-cli-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.skill = self.root / 'fixture/skills/wysiwag-verify'
        (self.skill / 'scripts').mkdir(parents=True)
        self.cli = self.skill / 'scripts/verify.py'
        shutil.copy2(SOURCE / 'verify.py', self.cli)
        shutil.copy2(SOURCE.parent / 'feature-map.md', self.skill / 'feature-map.md')
        (self.root / 'scripts').mkdir()
        stub = '''#!/usr/bin/env python3
import os, pathlib, sys
out = pathlib.Path(os.environ['WYSIWAG_EVIDENCE_DIR'])
(out / 'fixture.txt').write_text('fixture evidence\\n')
print('existing script received ' + repr(sys.argv[1:]))
sys.exit(int(os.environ.get('WYSIWAG_TEST_EXIT', '0')))
'''
        for name in ['core-e2e.sh', 'verify.sh']:
            script = self.root / 'scripts' / name
            script.write_text(stub)
            script.chmod(0o755)

    def run_cli(self, *args, code=0, env=None):
        result = subprocess.run([sys.executable, str(self.cli), *map(str, args)],
                                cwd=self.temp.name, env={**os.environ, **(env or {})},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, code, result.stdout + result.stderr)
        return result

    def test_list_has_every_capability_in_map(self):
        ids = [line.split('|')[1].strip().strip('`') for line in
               (self.skill / 'feature-map.md').read_text().splitlines() if line.startswith('| `')]
        self.assertEqual(len(ids), 29)
        result = self.run_cli('list')
        self.assertEqual([line.split('\t')[0] for line in result.stdout.splitlines()], ids)
        self.assertIn('live-capture', ids)

    def test_invalid_arguments_and_unknown_capability_fail(self):
        for args in [(), ('unknown',), ('check',), ('check', 'missing'),
                     ('evidence', 'ocr'), ('check', 'ocr', '--unknown'),
                     ('evidence', 'ocr', '--out')]:
            with self.subTest(args=args):
                self.run_cli(*args, code=2)
        self.assertFalse((self.root / '.build').exists())

    def test_check_runs_existing_script_and_records_evidence(self):
        self.run_cli('check', 'capture-all')
        out, = (self.root / '.build/verification/runs').iterdir()
        report = json.loads((out / 'run.json').read_text())
        self.assertEqual(report['status'], 'passed')
        self.assertEqual(report['commands'][0]['argv'], ['scripts/core-e2e.sh'])
        self.assertEqual((out / 'fixture.txt').read_text(), 'fixture evidence\n')

    def test_evidence_accepts_spaces_and_survives_inspection(self):
        out = self.root / 'proof with spaces'
        self.run_cli('evidence', 'ocr', '--out', out)
        before = {path.name: path.read_bytes() for path in out.iterdir()}
        result = self.run_cli('inspect', out)
        self.assertEqual(json.loads(result.stdout)['capability'], 'ocr')
        self.assertEqual({path.name: path.read_bytes() for path in out.iterdir()}, before)
        self.run_cli('evidence', 'ocr', '--out', out, code=2)
        self.assertEqual({path.name: path.read_bytes() for path in out.iterdir()}, before)

    def test_child_failure_is_returned_and_keeps_log(self):
        out = self.root / 'failure'
        self.run_cli('evidence', 'ocr', '--out', out, code=17, env={'WYSIWAG_TEST_EXIT': '17'})
        report = json.loads((out / 'run.json').read_text())
        self.assertEqual(report['exit_code'], 17)
        self.assertEqual(report['status'], 'failed')
        self.assertIn('existing script received', (out / 'check.log').read_text())
        self.assertTrue((out / 'fixture.txt').exists())

    def test_missing_executable_is_failure(self):
        (self.root / 'scripts/core-e2e.sh').unlink()
        self.run_cli('check', 'ocr', '--out', self.root / 'missing', code=127)
        self.assertEqual(json.loads((self.root / 'missing/run.json').read_text())['status'], 'failed')

    def test_child_exit_three_is_failure_not_prerequisite_block(self):
        out = self.root / 'exit-three'
        self.run_cli('check', 'ocr', '--out', out, code=3, env={'WYSIWAG_TEST_EXIT': '3'})
        self.assertEqual(json.loads((out / 'run.json').read_text())['status'], 'failed')

    def test_manual_capability_is_blocked_with_reason(self):
        out = self.root / 'manual'
        self.run_cli('evidence', 'live-capture', '--out', out, code=3)
        report = json.loads((out / 'run.json').read_text())
        self.assertEqual(report['status'], 'blocked')
        self.assertEqual(report['commands'], [])
        self.assertIn('Screen Recording', report['reason'])

    def test_all_delegates_to_verify_and_forwards_swift_options(self):
        out = self.root / 'all'
        self.run_cli('--swift-no-sandbox', 'all', '--out', out)
        command, = json.loads((out / 'run.json').read_text())['commands']
        self.assertEqual(command['argv'][0], 'scripts/verify.sh')
        self.assertIn('--disable-sandbox', command['argv'])
        self.assertIn(str(self.root / '.build/swift-cache'), command['argv'])

    def test_bad_map_cannot_report_success(self):
        path = self.skill / 'feature-map.md'
        path.write_text('| `ocr` | OCR | Drive | Observe | `typo` |\n')
        self.run_cli('list', code=2)

    def test_interrupt_cleans_up_child_and_preserves_evidence(self):
        script = self.root / 'scripts/core-e2e.sh'
        script.write_text('''#!/usr/bin/env python3
import os, pathlib, signal
out = pathlib.Path(os.environ['WYSIWAG_EVIDENCE_DIR'])
def terminate(signum, frame):
    raise SystemExit(128 + signum)
signal.signal(signal.SIGTERM, terminate)
try:
    (out / 'child.pid').write_text(str(os.getpid()))
    with open(os.environ['WYSIWAG_TEST_READY'], 'w') as ready:
        ready.write(str(os.getpid()) + '\\n')
    signal.pause()
finally:
    (out / 'cleaned.txt').write_text('cleaned')
''')
        out = self.root / 'interrupt'
        ready_path = self.root / 'child-started'
        os.mkfifo(ready_path)
        ready_fd = os.open(ready_path, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(os.close, ready_fd)
        launcher = '''import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
'''
        process = subprocess.Popen([sys.executable, '-c', launcher, str(self.cli), 'evidence', 'ocr', '--out', str(out)],
                                   env={**os.environ, 'WYSIWAG_TEST_READY': str(ready_path)},
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        child_pid = None
        child_reaped = False
        try:
            readable, _, _ = select.select([ready_fd], [], [], 15)
            self.assertTrue(readable, 'Synthetic child did not announce readiness')
            child_pid = int(os.read(ready_fd, 128))
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 130, stdout + stderr)
            self.assertEqual((out / 'cleaned.txt').read_text(), 'cleaned')
            self.assertEqual(json.loads((out / 'run.json').read_text())['exit_code'], 130)
            with self.assertRaises(ProcessLookupError):
                os.kill(child_pid, 0)
            child_reaped = True
        finally:
            if process.poll() is None:
                process.kill()
            if not child_reaped:
                if child_pid is None and (out / 'child.pid').exists():
                    pid_text = (out / 'child.pid').read_text().strip()
                    if pid_text.isdecimal():
                        child_pid = int(pid_text)
                if child_pid is not None:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            process.communicate(timeout=5)

    def test_interrupt_after_child_completion_preserves_evidence(self):
        launcher = '''import runpy, subprocess, sys
original_wait = subprocess.Popen.wait
def wait_then_interrupt(child, timeout=None):
    original_wait(child, timeout=timeout)
    subprocess.Popen.wait = original_wait
    raise KeyboardInterrupt
subprocess.Popen.wait = wait_then_interrupt
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
'''
        out = self.root / 'completed-child'
        result = subprocess.run([sys.executable, '-c', launcher, str(self.cli),
                                 'evidence', 'ocr', '--out', str(out)],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 130, result.stdout + result.stderr)
        report = json.loads((out / 'run.json').read_text())
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['exit_code'], 130)
        self.assertEqual(report['commands'][0]['exit_code'], 130)
        self.assertEqual((out / 'fixture.txt').read_text(), 'fixture evidence\n')
        self.assertIn('existing script received', (out / 'check.log').read_text())

    def test_filter_is_forwarded_to_swift_test(self):
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        swift = bin_dir / 'swift'
        swift.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        swift.chmod(0o755)
        out = self.root / 'unit'
        self.run_cli('evidence', 'privacy', '--out', out, env={'PATH': str(bin_dir) + os.pathsep + os.environ['PATH']})
        report = json.loads((out / 'run.json').read_text())
        self.assertEqual(report['commands'][0]['argv'], ['swift', 'test', '--filter', 'privacyExclusionsAndValidation'])


if __name__ == '__main__':
    unittest.main()

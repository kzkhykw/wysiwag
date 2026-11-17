#!/usr/bin/env python3
"""Dispatch feature-map checks and retain each run's evidence."""
import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile

SKILL = Path(__file__).resolve().parents[1]
ROOT = SKILL.parents[2]


@dataclass(frozen=True)
class Capability:
    id: str
    title: str
    drive: str
    observe: str
    check: str


def capabilities():
    entries = {}
    for line in (SKILL / 'feature-map.md').read_text().splitlines():
        if not line.startswith('| `'):
            continue
        cells = [cell.strip().strip('`') for cell in line.strip('|').split('|')]
        if len(cells) != 5:
            raise ValueError('Feature-map rows must have five columns')
        capability = Capability(*cells)
        if not re.fullmatch(r'[a-z][a-z0-9-]*', capability.id) or capability.id in entries:
            raise ValueError('Invalid or duplicate capability ID')
        if capability.check not in {'core', 'app', 'package', 'verify', 'localization', 'manual'} and not re.fullmatch(r'unit:[A-Za-z0-9_]+', capability.check):
            raise ValueError('Unknown check recipe for ' + capability.id)
        entries[capability.id] = capability
    if not entries:
        raise ValueError('The feature map contains no capabilities')
    return entries


def commands(recipe, flags):
    if recipe.startswith('unit:'):
        return [['swift', 'test', *flags, '--filter', recipe.removeprefix('unit:')]]
    return {
        'core': [['scripts/core-e2e.sh', *flags]],
        'app': [['scripts/build-app.sh', *flags], ['scripts/app-e2e.sh']],
        'package': [['scripts/build-app.sh', *flags]],
        'verify': [['scripts/verify.sh', *flags]],
        'localization': [['python3', 'scripts/check-localization.py']],
        'manual': [],
    }[recipe]


def doctor(ui=False):
    problems = []
    for name in ['swift', 'python3', 'git'] + (['orca', 'osascript', 'screencapture'] if ui else []):
        if not shutil.which(name):
            problems.append('Missing executable: ' + name)
    if sys.platform != 'darwin':
        problems.append('WYSIWAG requires macOS 14+ and Xcode with Swift 6')
    for name in ['ocr-fixture.png', 'ocr-changed.png']:
        if not (ROOT / 'Sources/WYSIWAGCore/Resources' / name).is_file():
            problems.append('Missing bundled synthetic fixture: ' + name)
    if ui and sys.platform == 'darwin':
        session = subprocess.run(['/usr/sbin/ioreg', '-n', 'Root', '-d1'], capture_output=True, text=True)
        if session.returncode or '"CGSSessionScreenIsLocked"=Yes' in session.stdout:
            problems.append('Desktop state unavailable or locked')
        running = subprocess.run(['pgrep', '-x', 'WYSIWAG'], capture_output=True)
        if running.returncode == 0:
            problems.append('WYSIWAG is already running; do not share the UI test domain')
    return problems


def run_command(argv, env, log):
    log.write(('$ ' + ' '.join(argv) + '\n').encode())
    log.flush()
    try:
        child = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    except OSError as error:
        log.write((type(error).__name__ + ': could not start ' + argv[0] + '\n').encode())
        return 127
    try:
        code = child.wait()
    except KeyboardInterrupt:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        return 130
    return code if code >= 0 else 128 - code


def execute(capability, out, flags):
    if out is None:
        base = ROOT / '.build/verification/runs'
        base.mkdir(parents=True, exist_ok=True)
        out = Path(tempfile.mkdtemp(prefix=capability.id + '-', dir=base))
    else:
        out = Path(out).resolve()
        if out.exists() and (not out.is_dir() or any(out.iterdir())):
            raise ValueError('Evidence directory must be new or empty')
        out.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env['WYSIWAG_EVIDENCE_DIR'] = str(out)
    env['CONFIGURATION'] = 'debug'
    report = {'capability': capability.id, 'recipe': capability.check, 'commands': [], 'exit_code': 0}
    if capability.check == 'manual':
        report.update(exit_code=3, reason=capability.observe)
    elif capability.check == 'app' and (problems := doctor(ui=True)):
        report.update(exit_code=3, reason='; '.join(problems))
    blocked = report['exit_code'] == 3
    with (out / 'check.log').open('wb') as log:
        if report['exit_code']:
            log.write((report['reason'] + '\n').encode())
        else:
            for argv in commands(capability.check, flags):
                code = run_command(argv, env, log)
                report['commands'].append({'argv': argv, 'exit_code': code})
                if code:
                    report['exit_code'] = code
                    break
    report['status'] = 'blocked' if blocked else 'passed' if report['exit_code'] == 0 else 'failed'
    report['artifacts'] = sorted(str(path.relative_to(out)) for path in out.rglob('*') if path.is_file())
    (out / 'run.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"{report['status'].upper()}: {capability.id}; evidence {out}")
    if 'reason' in report:
        print(report['reason'])
    return report['exit_code']


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swift-no-sandbox', action='store_true', help='disable SwiftPM nested sandbox and use repo-local SwiftPM caches')
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('list', help='list every feature-map capability and its check recipe')
    sub.add_parser('doctor', help='read-only toolchain/fixture preflight').add_argument('--ui', action='store_true')
    sub.add_parser('inspect', help='read a saved run manifest without rerunning').add_argument('directory', type=Path)
    for name in ['check', 'evidence']:
        action = sub.add_parser(name)
        action.add_argument('capability')
        action.add_argument('--out', type=Path, required=name == 'evidence')
    sub.add_parser('all', help='run the existing verify.sh baseline; UI and manual checks remain separate').add_argument('--out', type=Path)
    args = parser.parse_args(argv)
    try:
        entries = capabilities()
        if args.command == 'list':
            for entry in entries.values():
                print(f'{entry.id}\t{entry.title}\t{entry.check}')
            return 0
        if args.command == 'doctor':
            problems = doctor(args.ui)
            for problem in problems:
                print(problem)
            if not problems:
                print('READY: toolchain commands and synthetic fixtures available; run a check to prove behavior')
            return 3 if problems else 0
        if args.command == 'inspect':
            print(json.dumps(json.loads((args.directory / 'run.json').read_text()), indent=2))
            return 0
        if args.command == 'all':
            capability = Capability('all', 'Local automated baseline', '', '', 'verify')
            print('Running verify.sh; UI, live capture, live OAuth and independent review are separate checks.')
        else:
            if args.capability not in entries:
                raise ValueError('Unknown capability: ' + args.capability + '; use list')
            capability = entries[args.capability]
        flags = []
        if args.swift_no_sandbox:
            flags = ['--disable-sandbox', '--cache-path', str(ROOT / '.build/swift-cache'),
                     '--config-path', str(ROOT / '.build/swift-config'), '--security-path', str(ROOT / '.build/swift-security')]
        return execute(capability, args.out, flags)
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == '__main__':
    sys.exit(main())

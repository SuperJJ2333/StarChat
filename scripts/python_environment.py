"""Derive development install inputs without editing the production lock."""
import argparse
import hashlib
from importlib import metadata
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
PRODUCTION = ROOT / 'services/business-api/requirements.lock'
DEVELOPMENT = ROOT / 'scripts/requirements-dev.lock'


def locked_requirements(platform):
    pins = {}
    for path in (PRODUCTION, DEVELOPMENT):
        for raw in path.read_text(encoding='utf-8').splitlines():
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            match = re.fullmatch(r'([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+-]+)', line)
            if not match:
                raise ValueError(f'Expected an exact pin in {path.name}')
            name, version = match.groups()
            key = re.sub(r'[-_.]+', '-', name).lower()
            if key == 'uvloop' and platform == 'win32':
                continue
            if key in pins:
                raise ValueError(f'Duplicate pin: {name}')
            pins[key] = (name, version)
    return pins


def check_environment():
    if sys.flags.optimize:
        raise ValueError('Python optimization must be disabled; unset PYTHONOPTIMIZE and do not use -O')
    if sys.version_info[:2] != (3, 12) or sys.prefix == sys.base_prefix:
        raise ValueError('Use an isolated Python 3.12 environment; run scripts/bootstrap-python.ps1')
    config = Path(sys.prefix) / 'pyvenv.cfg'
    if not config.is_file() or re.search(r'include-system-site-packages\s*=\s*true',
                                       config.read_text(), re.IGNORECASE):
        raise ValueError('The virtual environment must exclude system site packages')
    problems = []
    for name, version in locked_requirements(sys.platform).values():
        try:
            installed = metadata.version(name)
        except metadata.PackageNotFoundError:
            installed = 'missing'
        if installed != version:
            problems.append(f'{name}: expected {version}, found {installed}')
    if problems:
        raise ValueError('Dependency lock mismatch: ' + '; '.join(problems))
    return {
        'executable': sys.executable,
        'version': sys.version.split()[0],
        'platform': sys.platform,
        'production_lock_sha256': hashlib.sha256(PRODUCTION.read_bytes()).hexdigest(),
        'development_lock_sha256': hashlib.sha256(DEVELOPMENT.read_bytes()).hexdigest(),
        'platform_exclusions': ['uvloop'] if sys.platform == 'win32' else [],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    lock = sub.add_parser('lock')
    lock.add_argument('--platform', choices=['win32', 'linux', 'darwin'], default=sys.platform)
    lock.add_argument('--output', type=Path, required=True)
    sub.add_parser('check')
    args = parser.parse_args()
    try:
        if args.command == 'lock':
            pins = locked_requirements(args.platform)
            args.output.write_text(''.join(f'{name}=={version}\n' for name, version in pins.values()),
                                   encoding='utf-8')
            print(f'Wrote {len(pins)} pinned requirements for {args.platform}')
        else:
            print(json.dumps(check_environment(), indent=2))
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

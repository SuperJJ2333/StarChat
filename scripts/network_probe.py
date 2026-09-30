"""Bounded public HTTPS measurements. No credentials, redirects or implicit proxy."""
from __future__ import annotations

import argparse
import ipaddress
import json
import math
import os
import re
import shutil
import subprocess
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / 'docs/verification/artifacts'


def validate_url(url: str) -> str:
    if len(url) > 2048 or any(char.isspace() or ord(char) < 32 for char in url):
        raise ValueError('Target must be a bounded HTTPS URL without whitespace')
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment
            or '?' in url or '#' in url or '\\' in url):
        raise ValueError('Target must be HTTPS with no credentials, query or fragment')
    if parsed.port is not None and not 1 <= parsed.port <= 65535:
        raise ValueError('Invalid HTTPS port')
    host = parsed.hostname
    try:
        ipaddress.ip_address(host)
    except ValueError:
        if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?', host):
            raise ValueError('Invalid target hostname') from None
    return url


def validate_output(path: str | Path) -> Path:
    resolved = Path(path).resolve()
    if not resolved.is_relative_to(ARTIFACTS.resolve()) or resolved == ARTIFACTS.resolve():
        raise ValueError('Output must be below docs/verification/artifacts')
    return resolved


def curl_command(curl: str, url: str, body: Path, *, timeout: float,
                 address: str | None = None) -> list[str]:
    validate_url(url)
    if not math.isfinite(timeout) or not 1 <= timeout <= 60:
        raise ValueError('Timeout must be 1..60 seconds')
    command = [curl, '--disable', '--silent', '--show-error', '--proto', '=https',
               '--proto-redir', '=https', '--noproxy', '*', '--proxy', '', '--retry', '0',
               '--connect-timeout', str(min(timeout, 10)), '--max-time', str(timeout),
               '--max-filesize', '16384', '--output', str(body), '--write-out', '%{json}']
    if address is not None:
        parsed = urlsplit(url)
        ip = ipaddress.ip_address(address)
        wire_address = f'[{ip}]' if ip.version == 6 else str(ip)
        command.extend(['--resolve', f'{parsed.hostname}:{parsed.port or 443}:{wire_address}'])
    command.extend(['--url', url])
    return command


def measurement(payload: dict, exit_code: int, *, address_override: bool,
                expected_status: int = 200) -> dict:
    def seconds(name):
        value = payload.get(name, 0)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return 0.0
        return float(value) if math.isfinite(value) and value >= 0 else 0.0

    dns, tcp, tls = (seconds(name) for name in
                     ('time_namelookup', 'time_connect', 'time_appconnect'))
    ttfb, total = seconds('time_starttransfer'), seconds('time_total')
    status = payload.get('http_code', payload.get('response_code', 0))
    status = status if type(status) is int and 0 <= status <= 599 else 0
    error = ({6: 'dns', 7: 'connect', 28: 'timeout', 35: 'tls', 60: 'tls',
              63: 'response_too_large'}.get(exit_code, 'transport') if exit_code
             else None if status == expected_status else 'http_status')
    remote = payload.get('remote_ip')
    try:
        remote = str(ipaddress.ip_address(remote))
    except (ValueError, TypeError):
        remote = None
    return {'success': error is None, 'error': error, 'curl_exit': exit_code,
            'http_status': status, 'remote_ip': remote,
            'dns_bypassed': address_override,
            'dns_ms': None if address_override or dns == 0 else dns * 1000,
            'tcp_ms': max(0, tcp - dns) * 1000 if tcp > 0 else None,
            'tls_ms': max(0, tls - tcp) * 1000 if tls > 0 else None,
            'ttfb_ms': ttfb * 1000 if ttfb > 0 else None, 'total_ms': total * 1000}


def probe_once(url: str, *, workdir: Path, timeout: float = 10,
               address: str | None = None, expect_status: int = 200,
               expect_json: tuple[str, str] | None = None,
               runner=subprocess.run, curl: str | None = None) -> dict:
    body = workdir / f'.probe-body-{uuid.uuid4().hex}'
    command = curl_command(curl or shutil.which('curl') or 'curl', url, body,
                           timeout=timeout, address=address)
    try:
        try:
            process = runner(command, capture_output=True, text=True, encoding='utf-8',
                             timeout=timeout + 3, check=False)
            try:
                payload = json.loads(process.stdout)
                if not isinstance(payload, dict):
                    payload = {}
            except (ValueError, TypeError):
                payload = {}
            row = measurement(payload, process.returncode, address_override=address is not None,
                              expected_status=expect_status)
            if not payload and process.returncode == 0:
                row.update(success=False, error='invalid_curl_metadata')
        except subprocess.TimeoutExpired:
            row = measurement({'time_total': timeout}, 28, address_override=address is not None)
        except OSError:
            row = measurement({}, 127, address_override=address is not None)
        if row['success'] and expect_json:
            try:
                if body.stat().st_size > 16384:
                    raise ValueError('Oversized body')
                parsed = json.loads(body.read_text(encoding='utf-8'))
                key, value = expect_json
                if not isinstance(parsed, dict) or parsed.get(key) != value:
                    raise ValueError('Unexpected JSON health')
            except (OSError, ValueError, UnicodeError):
                row.update(success=False, error='health_mismatch')
        return row
    finally:
        body.unlink(missing_ok=True)


def label(value: str) -> str:
    if not 1 <= len(value) <= 64 or any(ord(char) < 32 for char in value):
        raise argparse.ArgumentTypeError('Labels must be 1..64 characters without controls')
    return value


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', action='append', required=True, help='name=https://public-host/path')
    parser.add_argument('--address', action='append', default=[], help='name=IP; bypasses DNS explicitly')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--count', type=int, default=3)
    parser.add_argument('--interval', type=float, default=1)
    parser.add_argument('--timeout', type=float, default=10)
    parser.add_argument('--route', choices=['origin', 'edge-path', 'candidate-app'], default='origin')
    parser.add_argument('--vantage', type=label, required=True)
    parser.add_argument('--country', type=label, default='unknown')
    parser.add_argument('--carrier', type=label, default='unknown')
    parser.add_argument('--network', choices=['unknown', 'wifi', 'mobile', 'ethernet', 'vpn', 'none', 'other'], default='unknown')
    parser.add_argument('--expect-json', help='field=value, optional public health assertion')
    args = parser.parse_args(argv)
    try:
        if (not 1 <= args.count <= 1000 or not math.isfinite(args.interval)
                or not 0 <= args.interval <= 3600 or not 1 <= args.timeout <= 60):
            raise ValueError('Count 1..1000, interval 0..3600, timeout 1..60 required')
        targets = {}
        for target in args.target:
            name, url = target.split('=', 1)
            if not re.fullmatch(r'[a-zA-Z0-9_-]{1,32}', name) or name in targets:
                raise ValueError('Target names must be unique, 1..32 ASCII letters/digits/_/-')
            targets[name] = validate_url(url)
        if len(targets) > 8:
            raise ValueError('At most eight explicit targets')
        addresses = {}
        for override in args.address:
            name, address = override.split('=', 1)
            if name not in targets or name in addresses:
                raise ValueError('Address must name one target exactly once')
            addresses[name] = str(ipaddress.ip_address(address))
        expectation = None
        if args.expect_json:
            key, value = args.expect_json.split('=', 1)
            if not re.fullmatch(r'[a-zA-Z0-9_]{1,32}', key) or len(value) > 64:
                raise ValueError('Expected health metadata must be bounded')
            expectation = (key, value)
        output = validate_output(args.output)
    except (ValueError, TypeError):
        parser.error('Invalid target, label, bounds, address or artifact path; no request sent')
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('a', encoding='utf-8', newline='\n') as stream:
        for iteration in range(args.count):
            paired = str(uuid.uuid4())
            order = list(targets.items())
            if iteration % 2:
                order.reverse()
            for name, url in order:
                started = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
                row = {'schema_version': 1, 'record_type': 'https_probe',
                       'sample_id': str(uuid.uuid4()), 'pair_id': paired, 'started_at': started,
                       'target_id': name, 'route': args.route, 'vantage': args.vantage,
                       'country': args.country, 'carrier': args.carrier, 'network': args.network,
                       'labels_source': 'operator_declared', 'proxy_mode': 'disabled_environment',
                       'transparent_routing': 'unverified',
                       **probe_once(url, workdir=output.parent, timeout=args.timeout,
                                    address=addresses.get(name), expect_json=expectation)}
                stream.write(json.dumps(row, ensure_ascii=True, separators=(',', ':')) + '\n')
                stream.flush()
            if iteration + 1 < args.count:
                time.sleep(args.interval)
    print(json.dumps({'output': str(output), 'attempts': args.count * len(targets),
                      'scope': 'HTTPS only; not chat, TURN or main-region qualification'}))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

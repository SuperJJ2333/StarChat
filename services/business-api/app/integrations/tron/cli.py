"""Dedicated watch-only process: no business database or signing credentials."""
import argparse
import json
import os
from pathlib import Path
import time
from . import diagnostics as diag


def load_config(env):
    from .reader import validate_tron_address

    address = validate_tron_address(env.get('TRON_WATCH_ADDRESS', ''))
    start = int(env.get('TRON_WATCH_START_MS', '-1'))
    interval = int(env.get('TRON_WATCH_INTERVAL_SECONDS', '30'))
    batch_days = int(env.get('TRON_WATCH_BATCH_DAYS', '1'))
    if start < 0 or not 10 <= interval <= 60 or not 1 <= batch_days <= 30:
        raise ValueError('invalid watch configuration')
    return dict(address=address, start_ms=start, interval=interval, batch_ms=batch_days * 86400000,
                api_key=env.get('TRON_WATCH_API_KEY') or None)


def write_status(path, result, *, now_ms):
    path = Path(path)
    allowed = {'status', 'checkpoint_ms', 'events_added', 'outflows_added',
               'reconciliation', 'error_code', 'lag_ms', 'coverage_start_ms',
               'solid_block', 'live_outflows_added', 'historical_outflows_added'}
    payload = {key: value for key, value in result.items() if key in allowed}
    payload.update(checked_at_ms=now_ms, mode='WATCH_ONLY',
                   source='TRONGRID_SINGLE_SOURCE', watermark_kind='SOURCE_TRAVERSAL',
                   caught_up=result.get('status') == 'OK' and 0 <= result.get('lag_ms', 120001) <= 120000,
                   financial_writes_enabled=False, external_notification_delivery=False)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(payload, sort_keys=True) + '\n', encoding='utf-8')
    temporary.replace(path)


def healthy(path, *, now_ms):
    try:
        data = json.loads(Path(path).read_text(encoding='utf-8'))
        return data['status'] == 'OK' and 0 <= now_ms - data['checked_at_ms'] < 120000
    except (OSError, ValueError, KeyError, TypeError):
        return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--health', action='store_true')
    args = parser.parse_args()
    directory = Path(os.environ.get('TRON_WATCH_DATA_DIR', '/data'))
    def now():
        return time.time_ns() // 1000000
    if args.health:
        return 0 if healthy(directory / 'status.json', now_ms=now()) else 1
    diag.configure('tron-watch')
    diag.emit('INFO', 'service_started', component='cli')
    os.umask(0o077)
    try:
        config = load_config(os.environ)
        if config['start_ms'] > now():
            raise ValueError('future start')
    except Exception:
        print(json.dumps({'status': 'ERROR', 'error_code': 'WATCH_CONFIG_INVALID'}), flush=True)
        return 1
    from .observer import Observer
    from .reader import TronReader

    directory.mkdir(parents=True, exist_ok=True)
    reader = TronReader(api_key=config['api_key'])
    observer = Observer(directory / 'observations.sqlite3', reader, config['address'],
                        now_ms=now, start_ms=config['start_ms'], batch_ms=config['batch_ms'])
    while True:
        try:
            result = observer.run_once()
        except Exception as exc:
            diag.emit('ERROR', 'scan_failed', component='cli', reason_code='WATCH_SCAN_FAILED', **diag.exception_info(exc))
            result = {'status': 'ERROR', 'error_code': 'WATCH_SCAN_FAILED'}
        write_status(directory / 'status.json', result, now_ms=now())
        print((directory / 'status.json').read_text(encoding='utf-8').strip(), flush=True)
        if args.once:
            return 0 if result.get('status') == 'OK' else 1
        time.sleep(config['interval'])


if __name__ == '__main__':
    raise SystemExit(main())

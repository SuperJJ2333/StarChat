"""Exercise clock-reference HTTP validation through urllib's handler pipeline."""
from email.message import Message
import importlib.util
import io
import json
from pathlib import Path
from types import SimpleNamespace
import urllib.request
from urllib.response import addinfourl

import pytest

from app.modules.wallet import clock_health


REFERENCE = 'https://www.cloudflare.com/cdn-cgi/trace'
STAMP = 'Thu, 10 Sep 2026 10:59:13 GMT'
EPOCH = 1789037953.0


def transport(monkeypatch, *, dates=(STAMP,), age=None, code=200,
              changed_url=False, redirect=None, wall_jump=0):
    seen = []
    real_build_opener = urllib.request.build_opener

    class FakeHTTPS(urllib.request.HTTPSHandler):
        def https_open(self, request):
            seen.append(request)
            if len(seen) > 1:
                pytest.fail('Reference redirect target must never be contacted')
            headers = Message()
            for date in dates:
                headers.add_header('Date', date)
            if age is not None:
                headers.add_header('Age', age)
            if redirect is not None:
                headers.add_header('Location', redirect)
            response = addinfourl(io.BytesIO(b''), headers,
                'https://changed.invalid/' if changed_url else request.full_url,
                code=code)
            response.msg = 'Test response'
            return response

    def build(*handlers):
        proxies = [h for h in handlers if isinstance(h, urllib.request.ProxyHandler)]
        assert len(proxies) == 1 and proxies[0].proxies == {}
        return real_build_opener(*handlers, FakeHTTPS())

    mono = iter((100.0, 100.2))
    wall = iter((EPOCH + .5, EPOCH + .7 + wall_jump))
    monkeypatch.setattr(clock_health.urllib.request, 'build_opener', build)
    monkeypatch.setattr(clock_health.time, 'monotonic', lambda: next(mono))
    monkeypatch.setattr(clock_health.time, 'time', lambda: next(wall))
    return seen


def test_fresh_https_date_uses_nonce_and_explicit_cache_bypass(monkeypatch):
    seen = transport(monkeypatch)
    offset, rtt = clock_health.probe_utc(REFERENCE)
    assert offset == pytest.approx(.1)
    assert rtt == pytest.approx(.2)
    assert seen[0].full_url.startswith(REFERENCE + '?clock_probe=')
    assert seen[0].get_header('Cache-control') == 'no-cache, no-store'
    assert seen[0].get_header('Pragma') == 'no-cache'


@pytest.mark.parametrize('kwargs', [
    {'dates': ()},
    {'dates': (STAMP, STAMP)},
    {'dates': ('invalid date',)},
    {'dates': ('Thu, 10 Sep 2026 10:59:13 -0000',)},
    {'age': '12'},
    {'age': 'invalid'},
    {'changed_url': True},
    {'wall_jump': 20},
])
def test_unusable_http_evidence_is_rejected(monkeypatch, kwargs):
    transport(monkeypatch, **kwargs)
    with pytest.raises(ValueError):
        clock_health.probe_utc(REFERENCE)


@pytest.mark.parametrize('code', [301, 302, 303, 307, 308])
def test_redirect_is_rejected_before_following_target(monkeypatch, code):
    seen = transport(monkeypatch, code=code,
        redirect='https://redirect-target.invalid/time')
    with pytest.raises(ValueError, match='redirects forbidden'):
        clock_health.probe_utc(REFERENCE)
    assert len(seen) == 1


def test_http_error_never_becomes_a_clock_sample(monkeypatch):
    transport(monkeypatch, code=503)
    with pytest.raises(urllib.error.HTTPError):
        clock_health.probe_utc(REFERENCE)


def load_feed():
    source = Path(__file__).resolve().parents[3] / 'scripts/starchat_clock_feed.py'
    spec = importlib.util.spec_from_file_location('clock_feed_under_test', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize('samples, expected', [
    ([(60, .2), (60.5, .3)], True),
    ([(-60, .2), (-60.5, .3)], True),
    ([(120.1, .1), (120.1, .1)], False),
    ([(-120.1, .1), (-120.1, .1)], False),
    ([(60, .2), (63, .2)], False),
    ([(60, 2.1), (60, .2)], False),
    ([(60, -.1), (60, .2)], False),
    ([(60, .1)], False),
    ([], False),
    ([(float('nan'), .1), (60, .1)], False),
    ([(float('inf'), .1), (60, .1)], False),
])
def test_correction_sources_are_bounded_separately_from_host_health(samples, expected):
    assert load_feed().acceptable(samples) is expected


def feed_environment(monkeypatch, samples, *, apply, previous_state=None, monotonic=100.):
    feed = load_feed()
    calls = []
    files = {'/proc/sys/kernel/random/boot_id': 'current-boot\n'}
    if previous_state is not None:
        files['/var/lib/starchat-clock/feed.json'] = json.dumps(previous_state)

    class ManagedPath:
        def __init__(self, value):
            self.value = value

        def resolve(self):
            return self

        def __str__(self):
            return self.value

        def __truediv__(self, other):
            return ManagedPath(self.value + '/' + other)

        def read_text(self):
            if self.value in files:
                return files[self.value]
            assert self.value.endswith('/chrony.conf')
            return ('manual\nmaxdrift 500\nmaxslewrate 100000\nport 0\ncmdport 0\n'
                'bindcmdaddress /run/starchat-clock/chronyd.sock\n'
                'pidfile /run/starchat-clock/chronyd.pid\n'
                'driftfile /var/lib/starchat-clock/drift\n')

        def exists(self):
            return self.value in files

        def write_text(self, value):
            files[self.value] = value

        def with_suffix(self, suffix):
            return ManagedPath(self.value.rsplit('.', 1)[0] + suffix)

        def chmod(self, mode):
            assert mode == 0o600

    reference_module = SimpleNamespace(SOURCES=('first', 'second'),
        probe_utc=lambda source: samples[0 if source == 'first' else 1])
    monkeypatch.setattr(feed, 'Path', ManagedPath)
    monkeypatch.setattr(feed.argparse._sys, 'argv', ['clock_feed', '--directory',
        '/opt/starchat/releases/clock-test', *(['--apply'] if apply else [])])
    monkeypatch.setattr(feed.importlib.util, 'spec_from_file_location',
        lambda *args: SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module: None)))
    monkeypatch.setattr(feed.importlib.util, 'module_from_spec', lambda spec: reference_module)
    monkeypatch.setattr(feed.subprocess, 'run', lambda args, **kwargs: calls.append((args, kwargs)))
    monkeypatch.setattr(feed.time, 'monotonic', lambda: monotonic)
    monkeypatch.setattr(feed.time, 'time', lambda: EPOCH)
    monkeypatch.setattr(feed.os, 'replace', lambda source, target:
        files.__setitem__(str(target), files.pop(str(source))))
    feed._test_files = files
    return feed, calls


def test_correction_dry_run_never_invokes_chronyc(monkeypatch, capsys):
    feed, calls = feed_environment(monkeypatch, [(60, .2), (60, .2)], apply=False)
    feed.main()
    assert not calls
    report = json.loads(capsys.readouterr().out)
    assert report['healthy'] is False
    assert report['apply_requested'] is False


def test_rejected_sources_cannot_execute_a_correction(monkeypatch):
    feed, calls = feed_environment(monkeypatch, [(60, .2), (64, .2)], apply=True)
    with pytest.raises(SystemExit, match='references rejected'):
        feed.main()
    assert not calls


def test_step_capable_configuration_cannot_execute_correction(monkeypatch):
    feed, calls = feed_environment(monkeypatch, [(60, .2), (60, .2)], apply=True)
    original_read = feed.Path.read_text
    monkeypatch.setattr(feed.Path, 'read_text',
        lambda path: original_read(path) + 'makestep 1 3\n')
    with pytest.raises(SystemExit, match='unexpected effective clock configuration'):
        feed.main()
    assert not calls


def test_valid_unhealthy_offset_uses_only_local_manual_source_command(monkeypatch, capsys):
    feed, calls = feed_environment(monkeypatch, [(60, .2), (60, .2)], apply=True)
    feed.main()
    assert len(calls) == 1
    command, options = calls[0]
    assert command == ['/opt/starchat/releases/clock-test/usr/bin/chronyc', '-h',
        '/run/starchat-clock/chronyd.sock', 'settime', '2026-09-10 10:58:13']
    assert options['check'] is True
    assert options['timeout'] == 10
    assert options['env']['TZ'] == 'UTC'
    assert json.loads(capsys.readouterr().out)['healthy'] is False


def test_repeated_feed_in_same_boot_cannot_add_a_second_close_sample(monkeypatch):
    feed, calls = feed_environment(monkeypatch, [(60, .2), (60, .2)], apply=True)
    feed.main()
    feed.main()
    assert len(calls) == 1
    assert json.loads(feed._test_files['/var/lib/starchat-clock/feed.json']) == {
        'boot_id': 'current-boot', 'monotonic': 100.}


@pytest.mark.parametrize('elapsed, expected_calls', [(1, 0), (299.9, 0), (300, 1), (301, 1)])
def test_minimum_spacing_uses_monotonic_seconds(monkeypatch, elapsed, expected_calls):
    feed, calls = feed_environment(monkeypatch, [(60, .2), (60, .2)], apply=True,
        previous_state={'boot_id': 'current-boot', 'monotonic': 0}, monotonic=elapsed)
    feed.main()
    assert len(calls) == expected_calls


def test_previous_boot_monotonic_value_does_not_block_new_boot(monkeypatch):
    feed, calls = feed_environment(monkeypatch, [(60, .2), (60, .2)], apply=True,
        previous_state={'boot_id': 'previous-boot', 'monotonic': 999999})
    feed.main()
    assert len(calls) == 1


def test_failed_chronyc_does_not_record_successful_feed_time(monkeypatch):
    feed, _ = feed_environment(monkeypatch, [(60, .2), (60, .2)], apply=True)

    def fail(*args, **kwargs):
        raise OSError('chronyc unavailable')

    monkeypatch.setattr(feed.subprocess, 'run', fail)
    with pytest.raises(OSError, match='chronyc unavailable'):
        feed.main()
    assert '/var/lib/starchat-clock/feed.json' not in feed._test_files

from app.modules.wallet.clock_health import ClockHealth


def test_independent_sources_must_agree_and_host_must_be_close():
    assert ClockHealth(probe=lambda _: (0.5, 0.2)).trusted()
    assert not ClockHealth(probe=lambda _: (60, 0.2)).trusted()
    assert not ClockHealth(probe=lambda url: (0 if 'cloudflare' in url else 4, 0.2)).trusted()
    assert not ClockHealth(probe=lambda _: (0, 5)).trusted()


def test_failed_reference_fails_closed():
    def fail(_):
        raise OSError('unavailable')
    assert not ClockHealth(probe=fail).trusted()


def test_default_probe_is_killable_and_timeout_fails_closed(monkeypatch):
    import subprocess
    from app.modules.wallet import clock_health
    calls = []
    def timeout(command, **kwargs):
        calls.append((command, kwargs))
        raise subprocess.TimeoutExpired(command, kwargs['timeout'])
    monkeypatch.setattr(clock_health.subprocess, 'run', timeout)
    assert not ClockHealth().trusted()
    assert calls[0][1]['timeout'] == 6
    assert calls[0][0][-1] == '--probe'


def test_cache_expires_and_wallclock_jump_invalidates():
    clocks = [100., 100.]
    calls = []
    health = ClockHealth(probe=lambda u: (calls.append(u) or 0, .1),
        monotonic=lambda: clocks[0], wall=lambda: clocks[1])
    assert health.trusted()
    assert health.trusted() and len(calls) == 2
    clocks[1] += 20
    assert not health.trusted()

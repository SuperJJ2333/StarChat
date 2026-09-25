"""Guard recovery when the Caddyfile and live Caddy runtime diverge."""

from __future__ import annotations

import importlib.util
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest


@pytest.fixture
def probe():
    path = Path(__file__).resolve().parents[2] / "scripts/edge/starchat_public_probe.py"
    spec = importlib.util.spec_from_file_location("starchat_public_probe", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _original_file(probe, monkeypatch):
    original = b"original-caddyfile"
    monkeypatch.setattr(probe, "CONFIG", SimpleNamespace(read_bytes=lambda: original))
    monkeypatch.setattr(probe, "EXPECTED_ORIGINAL", probe.digest(original))
    monkeypatch.setattr(probe, "EXPECTED_RUNTIME", probe.json_digest({"site": "original"}))


def test_rollback_reloads_when_file_is_original_but_runtime_is_stale(
    probe, monkeypatch, capsys
):
    _original_file(probe, monkeypatch)
    live = Mock(side_effect=[{"site": "pilot"}, {"site": "original"}])
    reload_runtime = Mock()
    monkeypatch.setattr(probe, "live_config", live)
    monkeypatch.setattr(probe, "reload", reload_runtime)

    probe.rollback()

    reload_runtime.assert_called_once_with()
    assert live.call_count == 2
    assert '"passed": true' in capsys.readouterr().out


def test_rollback_never_reports_success_if_runtime_stays_stale(
    probe, monkeypatch, capsys
):
    _original_file(probe, monkeypatch)
    reload_runtime = Mock()
    monkeypatch.setattr(probe, "live_config", Mock(return_value={"site": "pilot"}))
    monkeypatch.setattr(probe, "reload", reload_runtime)

    with pytest.raises(RuntimeError, match="rollback-runtime-mismatch"):
        probe.rollback()

    reload_runtime.assert_called_once_with()
    assert capsys.readouterr().out == ""


def test_restore_backup_requires_live_runtime_to_match(probe, monkeypatch):
    _original_file(probe, monkeypatch)
    original = b"original-caddyfile"
    monkeypatch.setattr(probe, "BACKUP", SimpleNamespace(read_bytes=lambda: original))
    monkeypatch.setattr(probe, "ROLLBACK_DIR", object())
    monkeypatch.setattr(probe, "robocopy", Mock(return_value=object()))
    monkeypatch.setattr(probe.os, "replace", Mock())
    monkeypatch.setattr(probe, "validate", Mock())
    monkeypatch.setattr(probe, "reload", Mock())
    monkeypatch.setattr(probe, "live_config", Mock(return_value={"site": "pilot"}))

    with pytest.raises(RuntimeError, match="rollback-runtime-mismatch"):
        probe.restore_backup()

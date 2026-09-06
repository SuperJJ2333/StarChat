"""TURN certificate isolation and renewal safety; fixture bytes are not credentials."""
import importlib.util
import os
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def module():
    path = ROOT / "scripts/sync_turn_certificates.py"
    assert path.exists(), "TURN needs a restricted certificate synchronization helper"
    spec = importlib.util.spec_from_file_location("sync_turn_certificates", path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def test_turn_uses_isolated_certificate_mount():
    production = (ROOT / "docker-compose.production.yml").read_text(encoding="utf-8")
    assert "./data/coturn/certs:/etc/coturn/certs:ro" in production
    assert "./data/nginx/certs:/etc/nginx/certs:ro" in production
    assert "./data/nginx/certs:/etc/coturn/certs:ro" not in production


def test_sync_copies_pair_without_changing_source_permissions(tmp_path, monkeypatch):
    helper = module()
    source = tmp_path / "nginx"
    source.mkdir()
    for name in ("fullchain.pem", "privkey.pem"):
        (source / name).write_bytes(b"synthetic fixture only")
    os.chmod(source / "privkey.pem", 0o600)
    before = (source / "privkey.pem").stat().st_mode
    monkeypatch.setattr(helper, "validate_pair", lambda *args: None)
    ownership = []
    monkeypatch.setattr(helper.os, "chown", lambda p, u, g: ownership.append((Path(p).name, u, g)), raising=False)
    helper.sync_certificates(source, tmp_path / "turn", 65534)
    assert (tmp_path / "turn/privkey.pem").read_bytes() == b"synthetic fixture only"
    assert (source / "privkey.pem").stat().st_mode == before
    assert ownership and all(u == 0 and g == 65534 for _, u, g in ownership)
    if os.name == "posix":
        assert (tmp_path / "turn").stat().st_mode & 0o777 == 0o750
        assert (tmp_path / "turn/privkey.pem").stat().st_mode & 0o777 == 0o640


def test_invalid_renewal_preserves_live_pair(tmp_path, monkeypatch):
    helper = module()
    source, destination = tmp_path / "nginx", tmp_path / "turn"
    source.mkdir()
    destination.mkdir()
    for name in ("fullchain.pem", "privkey.pem"):
        (source / name).write_bytes(b"invalid new fixture")
        (destination / name).write_bytes(b"existing fixture")
    def reject(*args):
        raise ValueError("invalid certificate pair")
    monkeypatch.setattr(helper, "validate_pair", reject)
    with pytest.raises(ValueError, match="invalid certificate pair"):
        helper.sync_certificates(source, destination, 65534)
    assert (destination / "privkey.pem").read_bytes() == b"existing fixture"
    assert (destination / "fullchain.pem").read_bytes() == b"existing fixture"


def test_refuses_source_as_destination(tmp_path):
    helper = module()
    with pytest.raises(ValueError, match="separate"):
        helper.sync_certificates(tmp_path, tmp_path, 65534)


def test_renewal_hook_is_domain_scoped_and_syncs_before_restart():
    path = ROOT / "scripts/renew_turn_certificates.sh"
    assert path.exists(), "renewal must refresh the isolated TURN certificate pair"
    hook = path.read_text(encoding="utf-8")
    assert 'set -eu' in hook
    assert '"${RENEWED_LINEAGE:-}" = "/etc/letsencrypt/live/liuhetong888.com"' in hook
    assert hook.index("sync_turn_certificates.py") < hook.index("docker restart starchat-coturn-1")

"""Edge configuration safety and secret-file renderer behavior."""
import importlib.util
import os
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]
EDGE = ROOT / "infra/edge"


def helper():
    path = EDGE / "render_turn_config.py"
    assert path.exists(), "edge TURN must render from a protected secret file"
    spec = importlib.util.spec_from_file_location("edge_render_turn", path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def test_compose_is_stateless_host_network_with_bounded_logs():
    path = ROOT / "infra/compose/docker-compose.singapore-edge.yml"
    assert path.exists(), "approved edge compose must exist"
    config = yaml.safe_load(path.read_text(encoding="utf-8"))
    assert set(config["services"]) == {"edge-nginx", "edge-coturn"}
    assert not config.get("volumes")
    for service in config["services"].values():
        assert service["network_mode"] == "host"
        assert "latest" not in service["image"]
        assert service["read_only"] is True
        assert service["logging"]["options"] == {"max-size": "10m", "max-file": "3"}
        assert not service.get("environment")
        assert "ports" not in service
        assert all("data/" not in volume and volume.endswith(":ro") for volume in service["volumes"])
    turn = config["services"]["edge-coturn"]
    assert "auth-secret" not in str(turn["command"])
    assert turn["command"] == ["-c", "/etc/coturn/turnserver.conf"]
    assert "/var/lib/coturn:size=8m,mode=0755" in turn["tmpfs"]


def test_nginx_rejects_unknown_sni_and_keeps_origin_http_security():
    path = EDGE / "nginx-edge.conf"
    assert path.exists(), "edge nginx candidate must exist"
    config = path.read_text(encoding="utf-8")
    assert "map $ssl_preread_server_name $edge_upstream" in config
    assert "default unix:/var/run/edge-reject.sock;" in config
    for domain in ("liuhetong888.com", "admin.liuhetong888.com", "www.liuhetong888.com"):
        assert f"{domain} hk_tls;" in config
    assert "server 207.56.8.8:443;" in config
    assert "listen 127.0.0.1:8080;" in config
    assert "listen 80;" not in config
    assert "proxy_protocol on;" not in config
    assert "ssl_certificate" not in config
    assert "ssl_preread on;" in config


def test_render_uses_file_secret_and_blocks_internal_peer_networks(tmp_path):
    secret = tmp_path / "secret"
    secret.write_text("synthetic_fixture_secret_01234567890123456789\n", encoding="utf-8")
    destination = tmp_path / "runtime/turnserver.conf"
    helper().render(secret, destination, realm="liuhetong888.com", public_ip="13.229.60.153", private_ip="172.31.46.134")
    text = destination.read_text(encoding="utf-8")
    assert "static-auth-secret=synthetic_fixture_secret_01234567890123456789\n" in text
    # A public/private external-ip pair implicitly whitelists the private host
    # before denied-peer-ip checks. This node has one IPv4 relay behind AWS NAT.
    assert "external-ip=13.229.60.153\n" in text
    assert "external-ip=13.229.60.153/172.31.46.134\n" not in text
    assert "listening-ip=172.31.46.134\n" in text
    assert "relay-ip=172.31.46.134\n" in text
    for directive in ("min-port=49160", "max-port=49200", "user-quota=8", "total-quota=40", "no-cli", "no-tls", "no-dtls", "no-tcp-relay", "no-multicast-peers", "log-file=stdout", "userdb=/tmp/turn-runtime.db", "no-auth-pings", "no-dynamic-ip-list", "no-dynamic-realms"):
        assert directive + "\n" in text
    for address_range in ("127.0.0.0-127.255.255.255", "169.254.0.0-169.254.255.255", "10.0.0.0-10.255.255.255", "172.16.0.0-172.31.255.255", "192.168.0.0-192.168.255.255", "::1", "fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff"):
        assert f"denied-peer-ip={address_range}\n" in text
    assert "{{" not in text
    fields = dict(line.split("=", 1) for line in text.splitlines() if "=" in line and not line.startswith("#"))
    # coturn reserves max-bps for each allocation: capacity must fit the quota.
    assert int(fields["bps-capacity"]) // int(fields["max-bps"]) >= int(fields["total-quota"])
    assert "allow-loopback-peers" not in text
    assert "no-loopback-peers" not in text  # unsupported by the pinned coturn version
    if os.name == "posix":
        assert destination.stat().st_mode & 0o777 == 0o600
        assert destination.parent.stat().st_mode & 0o777 == 0o700


def test_turn_peer_policy_does_not_turn_unspecified_ipv6_into_global_deny():
    text = (EDGE / "turnserver.conf.template").read_text(encoding="utf-8")
    # coturn addr_any(::) makes a range universal, including public IPv4 peers.
    # The server itself rejects the native unspecified address as a peer.
    denied = [line.split("=", 1)[1] for line in text.splitlines() if line.startswith("denied-peer-ip=")]
    assert "::" not in denied
    assert "0.0.0.0" not in denied
    for retained in ("::1", "::ffff:0:0-::ffff:ffff:ffff", "fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
                     "fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "ff00::-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"):
        assert retained in denied


@pytest.mark.parametrize("field,value", [("realm", "evil\nno-auth"), ("public_ip", "127.0.0.1"), ("private_ip", "13.229.60.153"), ("private_ip", "172.31.46.134\nno-auth")])
def test_invalid_inputs_leave_existing_config_untouched(tmp_path, field, value):
    secret = tmp_path / "secret"
    secret.write_text("synthetic_fixture_secret_01234567890123456789", encoding="utf-8")
    destination = tmp_path / "turnserver.conf"
    destination.write_text("existing config", encoding="utf-8")
    inputs = dict(realm="liuhetong888.com", public_ip="13.229.60.153", private_ip="172.31.46.134")
    inputs[field] = value
    with pytest.raises(ValueError):
        helper().render(secret, destination, **inputs)
    assert destination.read_text(encoding="utf-8") == "existing config"


@pytest.mark.parametrize("value", ["short", "synthetic_fixture_secret_01234567890123456789\nno-auth", " " * 64])
def test_secret_injection_is_rejected_without_echoing_secret(tmp_path, value):
    secret = tmp_path / "secret"
    secret.write_text(value, encoding="utf-8")
    with pytest.raises(ValueError) as error:
        helper().render(secret, tmp_path / "turnserver.conf", realm="liuhetong888.com", public_ip="13.229.60.153", private_ip="172.31.46.134")
    assert value not in str(error.value)


def test_refuses_same_secret_and_destination_path(tmp_path):
    renderer = helper()
    secret = tmp_path / "secret"
    secret.write_text("synthetic_fixture_secret_01234567890123456789", encoding="utf-8")
    with pytest.raises(ValueError, match="separate"):
        renderer.render(secret, secret, realm="liuhetong888.com", public_ip="13.229.60.153", private_ip="172.31.46.134")


@pytest.mark.parametrize("which", ["secret", "destination"])
def test_refuses_symlink_inputs_without_touching_target(tmp_path, which):
    renderer = helper()
    secret = tmp_path / "secret"
    secret.write_text("synthetic_fixture_secret_01234567890123456789", encoding="utf-8")
    target = tmp_path / "target"
    target.write_text("untouched target", encoding="utf-8")
    link = tmp_path / "link"
    try:
        link.symlink_to(secret if which == "secret" else target)
    except OSError as error:
        pytest.skip(f"platform cannot create symlinks: {error.__class__.__name__}")
    with pytest.raises(ValueError, match="symbolic|regular"):
        renderer.render(link if which == "secret" else secret, link if which == "destination" else tmp_path / "turnserver.conf", realm="liuhetong888.com", public_ip="13.229.60.153", private_ip="172.31.46.134")
    assert target.read_text(encoding="utf-8") == "untouched target"

"""Pusher URLs must satisfy Synapse's exact canonical-path validation."""
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]


def test_canonical_push_path_selects_only_fixed_configured_upstreams():
    config = (ROOT / "infra/nginx/nginx.conf.template").read_text(encoding="utf-8")
    mapping = re.search(r"map\s+\$arg_provider\s+\$matrix_push_upstream\s*\{([^}]+)\}", config)
    assert mapping, "Getui must route through the canonical path with provider=getui"
    choices = dict(re.findall(r"(\w+)\s+(\w+);", mapping.group(1)))
    assert choices == {"default": "sygnal_upstream", "getui": "getui_bridge_upstream"}
    route = re.search(r"location\s+/_matrix/push/v1/notify\s*\{([^}]+)\}", config)
    assert route
    assert "proxy_pass http://$matrix_push_upstream;" in route.group(1)
    for upstream in choices.values():
        assert re.search(rf"upstream\s+{upstream}\s*\{{", config)


def test_legacy_getui_gateway_route_remains_compatible():
    config = (ROOT / "infra/nginx/nginx.conf.template").read_text(encoding="utf-8")
    assert "location /_matrix/push/v1/getui/" in config
    assert "proxy_pass http://getui_bridge_upstream;" in config

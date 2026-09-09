from pathlib import Path

import yaml


def test_chain_reader_mount_is_read_only_and_cannot_create_missing_source():
    root = Path(__file__).resolve().parents[2]
    config = yaml.safe_load((root / "infra/compose/docker-compose.wallet-chain.yml").read_text(encoding="utf-8"))
    service = config["services"]["business-api"]
    mount, = service["volumes"]
    assert mount["read_only"] is True
    assert mount["bind"]["create_host_path"] is False
    assert mount["target"] == "/data/tron-watch"
    assert service["environment"]["BUSINESS_TRON_OBSERVER_DATABASE_PATH"] == "/data/tron-watch/observations.sqlite3"
    assert "business-worker" not in config["services"]

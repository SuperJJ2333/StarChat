from pathlib import Path

import yaml


def test_tmpfs_options_are_one_mount_entry():
    configuration = yaml.safe_load(
        (Path(__file__).parents[1] / "compose.yaml").read_text(encoding="utf-8")
    )
    assert configuration["services"]["ios-call-gateway"]["tmpfs"] == [
        "/tmp:size=16m,mode=1777"
    ]

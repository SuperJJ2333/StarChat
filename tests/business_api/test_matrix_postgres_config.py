from pathlib import Path


ROOT = Path(__file__).parents[2]


def test_synapse_postgres_initializes_with_supported_c_locale() -> None:
    compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
    assert "POSTGRES_INITDB_ARGS" in compose
    assert "--locale=C --encoding=UTF8" in compose


def test_synapse_container_scripts_use_unix_line_endings() -> None:
    for path in (ROOT / "infra" / "synapse").glob("*.sh"):
        assert b"\r\n" not in path.read_bytes(), path.name


def test_bot_registration_is_non_interactive_and_non_admin() -> None:
    script = (ROOT / "infra" / "synapse" / "register_bot.sh").read_text(
        encoding="utf-8"
    )
    assert "--no-admin" in script


def test_matrix_voip_has_an_explicit_turn_relay() -> None:
    compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
    homeserver = (ROOT / "infra/synapse/homeserver.yaml.template").read_text(
        encoding="utf-8"
    )
    assert "coturn:" in compose
    assert "COTURN_IMAGE" in compose
    assert "--external-ip=${TURN_EXTERNAL_IP:?TURN_EXTERNAL_IP is required}" in compose
    assert "turn_uris:" in homeserver
    assert "turn_shared_secret:" in homeserver

from app.settings import Settings


def test_matrix_homeserver_url_is_normalized_for_matrix_nio_paths() -> None:
    settings = Settings(
        MATRIX_HOMESERVER_URL="https://matrix.example.test/",
        MATRIX_BOT_USER_ID="@notification:example.test",
        MATRIX_BOT_PASSWORD="test-password",
        MATRIX_INTERNAL_API_KEY="test-key",
    )

    assert settings.matrix_homeserver_url == "https://matrix.example.test"

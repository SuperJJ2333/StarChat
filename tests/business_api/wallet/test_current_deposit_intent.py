from test_deposit_receipts import core, intent  # noqa: F401


def test_current_intent_restores_only_calling_users_open_intent(core):
    service = core[3]
    assert service.current(user_id='alice') is None
    created = intent(core)
    assert service.current(user_id='alice') == created
    assert service.current(user_id='another-user') is None

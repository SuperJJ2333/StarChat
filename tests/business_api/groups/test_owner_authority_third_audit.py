from .test_group_transfer_coordination import env


def test_ambiguous_highest_power_is_desync(env):
    env[2].power_users = {'@owner:x':100, '@newowner:x':100}
    view = env[3].group_view('!room:x')
    assert view['owner_desync'] is True
    assert view['owner_authority_available'] is True


def test_unavailable_authority_is_explicit_unknown(env):
    def unavailable(room_id):
        raise TimeoutError()
    env[2].get_room_state = unavailable
    view = env[3].group_view('!room:x')
    assert view['owner_authority_available'] is False
    assert view['matrix_power_owner'] is None

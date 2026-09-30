import importlib.util
from pathlib import Path

import pytest

spec = importlib.util.spec_from_file_location("turn_renderer", Path(__file__).parents[2] / "infra/render_config.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


def test_default_keeps_original_turn_list():
    assert renderer.additional_turn_uris({}) == ""


def test_additional_uris_are_quoted_and_preserve_both_transports():
    data = {'TURN_ADDITIONAL_URIS_JSON': '["turn:sg.liuhetong888.com:3478?transport=udp", "turn:sg.liuhetong888.com:3478?transport=tcp"]'}
    assert renderer.additional_turn_uris(data) == '  - "turn:sg.liuhetong888.com:3478?transport=udp"\n  - "turn:sg.liuhetong888.com:3478?transport=tcp"'


@pytest.mark.parametrize("value", ['{}', 'null', '[1]', '["turn:sg.liuhetong888.com:3478?transport=udp\\nadmin: true"]', '["https://example.com"]', '["turn:user:password@example.com:3478?transport=udp"]', '["turn:169.254.169.254:3478?transport=udp"]', '["turn:sg.liuhetong888.com:3478?transport=udp", "turn:sg.liuhetong888.com:3478?transport=udp"]'])
def test_untrusted_or_duplicate_configuration_fails_closed(value):
    with pytest.raises(SystemExit):
        renderer.additional_turn_uris({'TURN_ADDITIONAL_URIS_JSON': value})


def test_template_cannot_override_generated_yaml():
    assert renderer.render('turn_uris:\n{{TURN_ADDITIONAL_URIS_YAML}}\n', {'TURN_ADDITIONAL_URIS_YAML': 'unsafe'}) == 'turn_uris:\n\n'

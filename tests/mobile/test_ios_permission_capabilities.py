"""Guard both the permission allowlist and the executed CocoaPods hook."""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
PODFILE = ROOT / "apps/mobile_flutter/ios/Podfile"
REQUIRED = {
    "PERMISSION_CAMERA=1",
    "PERMISSION_MICROPHONE=1",
    "PERMISSION_PHOTOS=1",
    "PERMISSION_PHOTOS_ADD_ONLY=1",
    "PERMISSION_NOTIFICATIONS=1",
}


def test_permission_plugin_enables_only_used_capabilities() -> None:
    definitions = set(re.findall(r"PERMISSION_[A-Z_]+=1", PODFILE.read_text(encoding="utf-8")))
    assert definitions == REQUIRED


@pytest.mark.skipif(shutil.which("ruby") is None, reason="Ruby required to execute CocoaPods hook")
def test_post_install_preserves_definitions_for_every_configuration() -> None:
    # Execute the real hook with CocoaPods-shaped objects; Flutter setup outside
    # the hook needs the macOS SDK, but must not be needed to test this mutation.
    script = r'''
require 'json'
require 'ostruct'
def flutter_additional_ios_build_settings(target)
  target.build_configurations.each { |config| config.build_settings['FLUTTER_CHECK'] = true }
end
def post_install
  configs = [
    OpenStruct.new(name: 'Debug', build_settings: {}),
    OpenStruct.new(name: 'Profile', build_settings: {'GCC_PREPROCESSOR_DEFINITIONS' => ['$(inherited)', 'EXISTING=1']}),
    OpenStruct.new(name: 'Release', build_settings: {'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) EXISTING=1'})
  ]
  target = OpenStruct.new(name: 'permission_handler_apple', build_configurations: configs)
  other = OpenStruct.new(name: 'unrelated_plugin', build_configurations: [OpenStruct.new(build_settings: {})])
  yield OpenStruct.new(pods_project: OpenStruct.new(targets: [target, other]))
  puts JSON.generate({configs: configs.map(&:build_settings), other: other.build_configurations.first.build_settings})
end
source = File.read(ARGV.fetch(0))
eval(source[source.index('post_install do |installer|')..], TOPLEVEL_BINDING)
'''
    result = subprocess.run(
        ["ruby", "-e", script, str(PODFILE)], check=True, capture_output=True, text=True
    )
    settings = json.loads(result.stdout)
    for index, config in enumerate(settings["configs"]):
        definitions = config["GCC_PREPROCESSOR_DEFINITIONS"]
        assert isinstance(definitions, list)
        assert REQUIRED <= set(definitions)
        assert "$(inherited)" in definitions
        assert config["FLUTTER_CHECK"] is True
        if index:
            assert "EXISTING=1" in definitions
    assert settings["other"] == {"FLUTTER_CHECK": True}

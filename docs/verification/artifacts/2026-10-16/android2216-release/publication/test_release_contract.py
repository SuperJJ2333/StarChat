"""Offline proofs over exact synthetic files; no transport or cloud calls."""
import copy
from contextlib import nullcontext
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / 'payload'))
import release_2216 as release
import delivery_2216 as delivery
import settings_2216 as settings


class ReleaseContract(unittest.TestCase):
    def fixture(self):
        base = HERE / 'test-scratch'
        base.mkdir(exist_ok=True)
        return tempfile.TemporaryDirectory(dir=base)

    def record(self):
        return release.record('a' * 64, 90000000, 'synthetic fixture',
                              'b' * 40, 'c' * 64)

    def test_target_2216_fixed_signer_and_missing_identity_rejected(self):
        target = self.record()
        self.assertEqual((target['version'], target['build']), ('0.4.47', 2216))
        self.assertEqual(target['signer_sha256'],
                         '75b31c66476cd8e2c9319551b49405a1de1e5c23e9a0dbdcc9eb76b52ba61fff')
        for sha, size in [('', 1), ('0' * 64, 1), ('a' * 64, 0), ('a' * 64, True),
                          (release.OLD_SHA, 1)]:
            with self.subTest(sha=sha, size=size), self.assertRaises(ValueError):
                release.record(sha, size, 'fixture', 'b' * 40, 'c' * 64)
        with self.assertRaises(ValueError):
            release.record('a' * 64, 1, 'fixture')

    def test_exact_android_three_keys_ios_2215_minimum_and_urls_preserved(self):
        before = copy.deepcopy(release.FROZEN_SETTINGS)
        after = release.settings_target(before)
        changed = {key for key in before if before[key] != after[key]}
        self.assertEqual(changed, {'app_latest_version', 'app_latest_build', 'app_update_notes'})
        self.assertEqual(after['app_latest_build'], '2216')
        self.assertEqual(after['app_ios_latest_build'], '2215')
        self.assertEqual(after['app_ios_latest_version'], '0.4.46')
        for key in before:
            if key not in changed:
                self.assertEqual(after[key], before[key])
        payload = dict(mode='apply', expected=before, after=after, trace='synthetic-2216-cas')
        self.assertEqual(settings.validate(payload), {key: after[key] for key in changed})
        for key in ('app_ios_latest_build', 'app_min_supported_build', 'app_apk_url'):
            wrong = copy.deepcopy(payload)
            wrong['after'][key] = 'drift'
            with self.subTest(key=key), self.assertRaises(ValueError):
                settings.validate(wrong)

    def test_page_edits_only_android_link_and_cache_tag(self):
        before = (HERE / 'payload/hk-snapshot/download.html').read_bytes()
        after = release.page_target(before)
        expected = before.replace(
            b'id="android-direct-download" href="/downloads/ChatFlow-0.4.46-build2215-arm64.apk"',
            b'id="android-direct-download" href="/downloads/ChatFlow-0.4.47-build2216-arm64.apk"')
        expected = expected.replace(b'src="/src/download-redirect.js?v=2215-network"',
                                    b'src="/src/download-redirect.js?v=2216-network"')
        self.assertEqual(after, expected)
        self.assertIn(b'ChatFlow-0.4.46-2215-enterprise-4087d408.ipa', after)
        with self.assertRaises(ValueError):
            release.page_target(after)

    def test_cloudfront_preserves_17_rules_and_only_appends_exact_2216_hk_rule(self):
        before = copy.deepcopy(release.FROZEN_CLOUDFRONT['DistributionConfig'])
        after = release.cloudfront_target(before)
        self.assertEqual(after['CacheBehaviors']['Quantity'], 18)
        self.assertEqual(after['CacheBehaviors']['Items'][:-1], before['CacheBehaviors']['Items'])
        old = next(item for item in before['CacheBehaviors']['Items']
                   if item['PathPattern'] == 'downloads/ChatFlow-0.4.46-build2215-arm64.apk')
        self.assertEqual(after['CacheBehaviors']['Items'][-1], old | {
            'PathPattern': 'downloads/ChatFlow-0.4.47-build2216-arm64.apk'})
        self.assertEqual({k: v for k, v in before.items() if k != 'CacheBehaviors'},
                         {k: v for k, v in after.items() if k != 'CacheBehaviors'})
        self.assertEqual(release.cloudfront_target(after), after)
        after['Origins']['Quantity'] += 1
        with self.assertRaises(ValueError):
            release.cloudfront_target(after)

    def test_cloud_fixed_account_role_bucket_and_policy(self):
        self.assertEqual(release.DIST, 'E30IR8IHK6PMXZ')
        self.assertEqual(release.BUCKET, 'starchat-installers-218022113852-sg')
        self.assertEqual(delivery.ROLE,
                         'arn:aws:sts::218022113852:assumed-role/StarChatSgMaintenanceRole/i-035b46916e4cf43eb')
        before = release.read_json(HERE / 'payload/bucket-policy-before.json')
        self.assertEqual(release.policy_target(before), before)
        self.assertIn('arn:aws:cloudfront::218022113852:distribution/E30IR8IHK6PMXZ', str(before))
        wrong = copy.deepcopy(before)
        wrong['Statement'][1]['Condition']['StringEquals']['AWS:SourceArn'] = 'foreign'
        with self.assertRaises(ValueError):
            release.policy_target(wrong)
        with patch.object(delivery, 'aws', return_value={'Account': '218022153852', 'Arn': delivery.ROLE}):
            with self.assertRaisesRegex(ValueError, 'account drift'):
                delivery.cloud_state({}, HERE)

    def test_unknown_and_partial_states_refused(self):
        self.assertEqual(release.classify({'a': 1}, {'a': 2}, {'a': 1}), 'before')
        self.assertEqual(release.classify({'a': 1}, {'a': 2}, {'a': 2}), 'complete')
        with self.assertRaises(ValueError):
            release.classify({'a': 1}, {'a': 2}, {'a': 3})

    def test_static_cas_backup_and_rollback_never_overwrite_newer_commit(self):
        with self.fixture() as name:
            tmp = Path(name); root = tmp / 'root'; stage = tmp / 'stage'
            root.mkdir(); stage.mkdir()
            (root / 'page').write_bytes(b'old'); (stage / 'page').write_bytes(b'new')
            (root / 'ios').write_bytes(b'ios2215')
            plan = {'static': {'page': {'before': release.sha(b'old'), 'after': release.sha(b'new')}},
                    'preserved': {'ios': release.sha(b'ios2215')}}
            backup = tmp / 'backup'
            release.apply_static(plan, root, stage, backup, lock=lambda _: nullcontext())
            self.assertEqual((backup / 'page').read_bytes(), b'old')
            self.assertEqual((root / 'ios').read_bytes(), b'ios2215')
            (root / 'page').write_bytes(b'newer')
            with self.assertRaises(ValueError):
                release.rollback_static(plan, root, backup, lock=lambda _: nullcontext())
            self.assertEqual((root / 'page').read_bytes(), b'newer')

    def test_unknown_database_commit_keeps_validated_pages_and_marks_inspect(self):
        with self.fixture() as name:
            backup = Path(name) / 'backup'; backup.mkdir()
            r = {'deployment': {'settings_after': {'a': 'new'}}}
            before = {'static': 'before', 'settings': 'before', 'alias': release.NAME,
                      'live_settings': {'a': 'old'}}
            with patch.object(release, 'host_lock', lambda _: nullcontext()), \
                    patch.object(release, 'check', return_value=before), \
                    patch.object(release, 'apply_static'), \
                    patch.object(release, 'public_check'), \
                    patch.object(release, 'db', side_effect=TimeoutError('commit unknown')), \
                    patch.object(release, 'rollback_static') as rollback, \
                    patch.object(Path, 'is_relative_to', return_value=True):
                with self.assertRaises(TimeoutError):
                    release.publish(r, Path(name), Path(name), backup, 'synthetic-2216-unknown')
            rollback.assert_not_called()
            self.assertIn('do not replay', (backup / 'outcome-unknown.json').read_text())

    def test_chunks_preserve_old_and_install_new_immutable_without_alias_switch(self):
        with self.fixture() as name:
            tmp = Path(name); source = tmp / 'input.apk'; source.write_bytes(b'new synthetic apk')
            record = self.record() | {'artifact_bytes': source.stat().st_size,
                                      'artifact_sha256': release.digest(source)}
            stage = tmp / 'stage'; delivery.split(record, source, stage)
            delivery.assemble(record, stage, lock=lambda _: nullcontext())
            root = tmp / 'root'; downloads = root / 'downloads'; downloads.mkdir(parents=True)
            old = downloads / release.OLD_NAME; old.write_bytes(b'old immutable apk')
            with patch.object(release, 'host_lock', lambda _: nullcontext()), \
                    patch.object(delivery, 'hk_state', return_value={'installed': False, 'alias': release.OLD_NAME}):
                delivery.hk(record, root, stage, 'hk-install')
            self.assertEqual(old.read_bytes(), b'old immutable apk')
            self.assertEqual((downloads / release.NAME).read_bytes(), source.read_bytes())
            self.assertFalse((downloads / 'latest-arm64.apk').exists())
            with self.assertRaises(FileExistsError), \
                    patch.object(release, 'host_lock', lambda _: nullcontext()), \
                    patch.object(delivery, 'hk_state', return_value={'installed': False, 'alias': release.OLD_NAME}):
                delivery.hk(record, root, stage, 'hk-install')


if __name__ == '__main__':
    unittest.main()

"""Offline administrator creation/resume boundaries; no AWS credentials/calls."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
from unittest.mock import Mock

import pytest

ROOT = Path(__file__).resolve().parents[2]
DIRECTORY = ROOT / 'infra/aws/installer-delivery'
sys.path.insert(0, str(DIRECTORY))
import distribution

OAC = 'E6P1PEF2BA7OK'
POLICY = '11111111-1111-4111-8111-111111112188'
DIST = 'E2EXAMPLECF2188'
CALLER = 'starchat-installer-2188-20260927'


def subject():
    path = DIRECTORY / 'admin_create.py'
    assert path.is_file(), 'administrator creation candidate is missing'
    spec = importlib.util.spec_from_file_location('installer_admin_create', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def config():
    return distribution.distribution_request(oac_id=OAC, caller_reference=CALLER,
        response_headers_policy_id=POLICY)['DistributionConfigWithTags']['DistributionConfig']


class FakeAWS:
    def __init__(self, existing=False):
        self.calls = []
        self.account = '218022113852'
        self.arn = 'arn:aws:sts::218022113852:assumed-role/InstallerAdmin/test'
        self.policy = existing
        self.dist = existing
        self.policy_config = distribution.response_headers_request()['ResponseHeadersPolicyConfig']
        self.dist_config = config()
        self.tags = [{'Key': 'Project', 'Value': 'StarChatInstallerDelivery'}]
        self.pages = {}
        self.fail_after_create = None

    def call(self, service, operation, request=None, request_file=None):
        if request_file is not None:
            request = json.loads(Path(request_file).read_text(encoding='utf-8'))
        self.calls.append((service, operation, copy.deepcopy(request)))
        if operation == 'get-caller-identity':
            return {'Account': self.account, 'Arn': self.arn}
        if operation == 'get-origin-access-control-config':
            return {'OriginAccessControlConfig': distribution.oac_request()['OriginAccessControlConfig']}
        if operation == 'list-response-headers-policies':
            if self.pages:
                return self.pages[request.get('Marker', '')]
            items = [{'Type': 'custom', 'ResponseHeadersPolicy': {'Id': POLICY,
                'ResponseHeadersPolicyConfig': self.policy_config}}] if self.policy else []
            return {'ResponseHeadersPolicyList': {'Items': items, 'Quantity': len(items)}}
        if operation == 'get-response-headers-policy-config':
            return {'ResponseHeadersPolicyConfig': self.policy_config}
        if operation == 'list-distributions':
            items = [{'Id': DIST, 'Origins': self.dist_config['Origins'],
                      'Comment': self.dist_config['Comment']}] if self.dist else []
            return {'DistributionList': {'Items': items, 'Quantity': len(items), 'IsTruncated': False}}
        if operation == 'get-distribution-config':
            return {'DistributionConfig': self.dist_config}
        if operation == 'list-tags-for-resource':
            return {'Tags': {'Items': self.tags}}
        if operation == 'create-response-headers-policy':
            assert request == distribution.response_headers_request()
            self.policy = True
            if self.fail_after_create == operation:
                raise RuntimeError('synthetic ambiguous success')
            return {'ResponseHeadersPolicy': {'Id': POLICY}}
        if operation == 'create-distribution-with-tags':
            assert request == distribution.distribution_request(oac_id=OAC,
                caller_reference=CALLER, response_headers_policy_id=POLICY)
            self.dist = True
            if self.fail_after_create == operation:
                raise RuntimeError('synthetic ambiguous success')
            return {'Distribution': {'Id': DIST}}
        if operation == 'get-distribution':
            return {'Distribution': {'Id': DIST,
                'ARN': f'arn:aws:cloudfront::218022113852:distribution/{DIST}',
                'DomainName': 'd123example.cloudfront.net', 'Status': 'InProgress'}}
        raise AssertionError(operation)


def writes(fake):
    return [op for _, op, _ in fake.calls if op.startswith('create-')]


def test_exact_new_creation_and_closed_summary(tmp_path):
    mod, fake = subject(), FakeAWS()
    result = mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == ['create-response-headers-policy', 'create-distribution-with-tags']
    assert set(result) == {'distribution_id', 'distribution_arn', 'domain', 'status',
                          'response_headers_policy_id', 'oac_id', 'caller_reference'}
    assert result['caller_reference'] == CALLER
    assert json.loads((tmp_path / 'artifact/summary.json').read_text()) == result
    assert not any(op.startswith(('update-', 'delete-', 'put-', 'tag-')) for _, op, _ in fake.calls)


@pytest.mark.parametrize('existing', [True, False])
def test_repeated_run_reuses_resources(tmp_path, existing):
    mod, fake = subject(), FakeAWS(existing)
    mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    count = len(writes(fake))
    mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert len(writes(fake)) == count


@pytest.mark.parametrize('operation', ['create-response-headers-policy', 'create-distribution-with-tags'])
def test_ambiguous_success_is_resumed_without_duplicate(tmp_path, operation):
    mod, fake = subject(), FakeAWS()
    fake.fail_after_create = operation
    with pytest.raises(RuntimeError):
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    fake.fail_after_create = None
    mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake).count(operation) == 1


@pytest.mark.parametrize('arn', [
    'arn:aws:sts::218022113852:assumed-role/StarChatSgMaintenanceRole/session',
    'arn:aws:iam::218022113852:role/StarChatSgMaintenanceRole',
])
def test_maintenance_role_stops_before_cloudfront(tmp_path, arn):
    mod, fake = subject(), FakeAWS()
    fake.arn = arn
    with pytest.raises(mod.CandidateError, match='ADMINISTRATOR_SESSION_REQUIRED'):
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert [op for _, op, _ in fake.calls] == ['get-caller-identity']


def test_wrong_account_stops_before_creation(tmp_path):
    mod, fake = subject(), FakeAWS()
    fake.account = '111111111111'
    with pytest.raises(mod.CandidateError, match='ACCOUNT_MISMATCH'):
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


def test_conflicting_policy_aborts_without_updates(tmp_path):
    mod, fake = subject(), FakeAWS(True)
    fake.policy_config = copy.deepcopy(fake.policy_config)
    fake.policy_config['CorsConfig']['AccessControlAllowCredentials'] = True
    with pytest.raises(mod.CandidateError, match='RESPONSE_HEADERS_CONFIG_MISMATCH'):
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


@pytest.mark.parametrize('change', ['caller', 'origin', 'tags', 'logging', 'header', 'extra', 'root_object'])
def test_existing_distribution_conflicts_abort(tmp_path, change):
    mod, fake = subject(), FakeAWS(True)
    if change == 'caller': fake.dist_config['CallerReference'] = 'different'
    if change == 'origin': fake.dist_config['Origins']['Items'][1]['DomainName'] = 'wrong.example'
    if change == 'tags': fake.tags = []
    if change == 'logging': fake.dist_config['Logging']['Enabled'] = True
    if change == 'header': fake.dist_config['DefaultCacheBehavior']['OriginRequestPolicyId'] = POLICY
    if change == 'extra': fake.dist_config['WebACLId'] = 'unexpected'
    if change == 'root_object': fake.dist_config['DefaultRootObject'] = 'index.html'
    with pytest.raises(mod.CandidateError):
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


def test_empty_aws_defaults_are_compatible(tmp_path):
    mod, fake = subject(), FakeAWS(True)
    fake.dist_config.update(WebACLId='', Staging=False, CustomErrorResponses={'Quantity': 0},
                            ContinuousDeploymentPolicyId='')
    fake.dist_config['ViewerCertificate'].update(MinimumProtocolVersion='TLSv1',
        CertificateSource='cloudfront', SSLSupportMethod='vip')
    fake.dist_config['DefaultCacheBehavior']['FieldLevelEncryptionId'] = ''
    mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


def test_aws_empty_default_root_object_is_compatible(tmp_path):
    mod, fake = subject(), FakeAWS(True)
    fake.dist_config['DefaultRootObject'] = ''
    mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


@pytest.mark.parametrize('enabled', [False, True])
@pytest.mark.parametrize('behavior', ['default', 'versioned'])
def test_observed_grpc_disabled_only_is_compatible(tmp_path, enabled, behavior):
    mod, fake = subject(), FakeAWS(True)
    target = fake.dist_config['DefaultCacheBehavior'] if behavior == 'default' else fake.dist_config['CacheBehaviors']['Items'][0]
    target['GrpcConfig'] = {'Enabled': enabled}
    if enabled:
        with pytest.raises(mod.CandidateError, match='DISTRIBUTION_CONFIG_MISMATCH'):
            mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    else:
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


def observed_response_mapping():
    """Finite mapped defaults from cloud-final sanitized projection, not raw logs."""
    actual = config()
    actual.update(DefaultRootObject='', Staging=False, WebACLId='',
                  ContinuousDeploymentPolicyId='', CustomErrorResponses={'Quantity': 0})
    actual['Origins']['Items'][0]['S3OriginConfig']['OriginReadTimeout'] = 30
    for origin in actual['Origins']['Items']:
        origin['OriginShield'] = {'Enabled': False}
    actual['Origins']['Items'][1]['OriginAccessControlId'] = ''
    actual['Origins']['Items'].reverse()
    for behavior in [actual['DefaultCacheBehavior'], actual['CacheBehaviors']['Items'][0]]:
        behavior.update(GrpcConfig={'Enabled': False}, FieldLevelEncryptionId='', SmoothStreaming=False)
        behavior['AllowedMethods']['Items'] = ['HEAD', 'GET']
        behavior['AllowedMethods']['CachedMethods']['Items'] = ['HEAD', 'GET']
    actual['OriginGroups']['Items'][0]['SelectionCriteria'] = 'default'
    actual['ViewerCertificate'].update(SSLSupportMethod='vip', CertificateSource='cloudfront',
                                       MinimumProtocolVersion='TLSv1')
    return actual


def test_mapped_real_response_is_reused_without_creation(tmp_path):
    mod, fake = subject(), FakeAWS(True)
    fake.dist_config = observed_response_mapping()
    mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


@pytest.mark.parametrize('field', ['origins_order', 'default_methods', 'versioned_methods',
                                  's3_read_timeout', 'group_selection'])
def test_each_observed_normalization_is_compatible(field):
    mod, actual = subject(), config()
    if field == 'origins_order': actual['Origins']['Items'].reverse()
    if field == 'default_methods':
        actual['DefaultCacheBehavior']['AllowedMethods']['Items'].reverse()
        actual['DefaultCacheBehavior']['AllowedMethods']['CachedMethods']['Items'].reverse()
    if field == 'versioned_methods':
        actual['CacheBehaviors']['Items'][0]['AllowedMethods']['Items'].reverse()
        actual['CacheBehaviors']['Items'][0]['AllowedMethods']['CachedMethods']['Items'].reverse()
    if field == 's3_read_timeout': actual['Origins']['Items'][0]['S3OriginConfig']['OriginReadTimeout'] = 30
    if field == 'group_selection': actual['OriginGroups']['Items'][0]['SelectionCriteria'] = 'default'
    assert mod._compatible(actual, config())


@pytest.mark.parametrize('drift', [
    'duplicate_origin_id', 'origin_id_changed', 'origin_binding_changed', 'oac_changed',
    'missing_origin', 'origin_quantity', 'primary_secondary_reversed', 'member_origin_id',
    'target_origin_id', 'group_target', 'methods_post', 'methods_duplicate',
    'methods_quantity', 'cached_methods_post', 'read_timeout_31', 'read_timeout_string',
    'read_timeout_bool', 'grpc_true', 'grpc_int', 'grpc_null', 'grpc_unknown',
    'selection_media', 'selection_null', 'group_unknown', 'config_etag',
])
def test_mapped_response_rejects_unapproved_values_and_references(drift):
    mod, actual = subject(), observed_response_mapping()
    origins = actual['Origins']['Items']
    s3 = next(origin for origin in origins if origin['Id'] == 'installer-s3')
    group = actual['OriginGroups']['Items'][0]
    behavior = actual['DefaultCacheBehavior']
    methods = behavior['AllowedMethods']
    if drift == 'duplicate_origin_id': origins[0]['Id'] = origins[1]['Id']
    if drift == 'origin_id_changed': origins[0]['Id'] = 'different'
    if drift == 'origin_binding_changed': origins[0]['DomainName'], origins[1]['DomainName'] = origins[1]['DomainName'], origins[0]['DomainName']
    if drift == 'oac_changed': s3['OriginAccessControlId'] = 'E22DIFFERENTOAC'
    if drift == 'missing_origin': origins.pop()
    if drift == 'origin_quantity': actual['Origins']['Quantity'] = 1
    if drift == 'primary_secondary_reversed': group['Members']['Items'].reverse()
    if drift == 'member_origin_id': group['Members']['Items'][0]['OriginId'] = 'dangling-origin'
    if drift == 'target_origin_id': behavior['TargetOriginId'] = 'dangling-origin'
    if drift == 'group_target': actual['CacheBehaviors']['Items'][0]['TargetOriginId'] = 'different-group'
    if drift == 'methods_post': methods['Items'] = ['GET', 'POST']
    if drift == 'methods_duplicate': methods['Items'] = ['GET', 'GET']
    if drift == 'methods_quantity': methods['Quantity'] = 1
    if drift == 'cached_methods_post': methods['CachedMethods']['Items'] = ['GET', 'POST']
    if drift == 'read_timeout_31': s3['S3OriginConfig']['OriginReadTimeout'] = 31
    if drift == 'read_timeout_string': s3['S3OriginConfig']['OriginReadTimeout'] = '30'
    if drift == 'read_timeout_bool': s3['S3OriginConfig']['OriginReadTimeout'] = True
    if drift == 'grpc_true': behavior['GrpcConfig']['Enabled'] = True
    if drift == 'grpc_int': behavior['GrpcConfig']['Enabled'] = 0
    if drift == 'grpc_null': behavior['GrpcConfig']['Enabled'] = None
    if drift == 'grpc_unknown': behavior['GrpcConfig']['Unknown'] = False
    if drift == 'selection_media': group['SelectionCriteria'] = 'media-quality-based'
    if drift == 'selection_null': group['SelectionCriteria'] = None
    if drift == 'group_unknown': group['Unknown'] = 'default'
    if drift == 'config_etag': actual['ETag'] = 'fixture-etag'
    assert not mod._compatible(actual, config())


def test_manual_pagination_finds_existing_policy(tmp_path):
    mod, fake = subject(), FakeAWS(True)
    fake.pages = {'': {'ResponseHeadersPolicyList': {'Quantity': 0, 'NextMarker': 'page2'}},
        'page2': {'ResponseHeadersPolicyList': {'Quantity': 1, 'Items': [
            {'Type': 'custom', 'ResponseHeadersPolicy': {'Id': POLICY,
             'ResponseHeadersPolicyConfig': fake.policy_config}}]}}}
    mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    calls = [request for _, op, request in fake.calls if op == 'list-response-headers-policies']
    assert calls == [{'Type': 'custom', 'MaxItems': '100'},
                     {'Type': 'custom', 'MaxItems': '100', 'Marker': 'page2'}]
    assert writes(fake) == []


def test_repeated_pagination_marker_aborts(tmp_path):
    mod, fake = subject(), FakeAWS()
    fake.pages = {'': {'ResponseHeadersPolicyList': {'Quantity': 0, 'NextMarker': 'x'}},
                  'x': {'ResponseHeadersPolicyList': {'Quantity': 0, 'NextMarker': 'x'}}}
    with pytest.raises(mod.CandidateError, match='INVALID_PAGINATION'):
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


def test_unrelated_existing_distribution_is_never_changed(tmp_path):
    mod, fake = subject(), FakeAWS(True)
    fake.dist = False
    call = fake.call
    def with_unrelated(service, operation, request=None, request_file=None):
        if operation == 'list-distributions':
            fake.calls.append((service, operation, request))
            return {'DistributionList': {'Quantity': 1, 'Items': [{
                'Id': 'E11LA69ZDOD790', 'Comment': 'unrelated',
                'Origins': {'Quantity': 1, 'Items': [{'DomainName': 'chat-flow-total.s3.amazonaws.com'}]}}],
                'IsTruncated': False}}
        return call(service, operation, request, request_file)
    fake.call = with_unrelated
    # Inventory outside the candidate remains read-only; create still uses fixed caller.
    mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == ['create-distribution-with-tags']
    assert not any(request and request.get('Id') == 'E11LA69ZDOD790'
                   for _, _, request in fake.calls)


def test_oac_and_identity_preflight_fail_closed(tmp_path):
    mod, fake = subject(), FakeAWS()
    with pytest.raises(mod.CandidateError, match='APPROVED_OAC_REQUIRED'):
        mod.run(oac_id='E22OLDORIGIN', output=tmp_path / 'artifact', aws=fake)
    assert fake.calls == []
    fake.arn = 'arn:aws:sts::111111111111:assumed-role/Admin/test'
    with pytest.raises(mod.CandidateError, match='IDENTITY_INVALID'):
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


def test_duplicate_response_headers_policy_aborts(tmp_path):
    mod, fake = subject(), FakeAWS(True)
    item = {'ResponseHeadersPolicy': {'Id': POLICY, 'ResponseHeadersPolicyConfig': fake.policy_config}}
    fake.pages = {'': {'ResponseHeadersPolicyList': {'Quantity': 2, 'Items': [item, item]}}}
    with pytest.raises(mod.CandidateError, match='DUPLICATE_RESPONSE_HEADERS_POLICY'):
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


def test_existing_distribution_without_named_policy_aborts_before_creation(tmp_path):
    mod, fake = subject(), FakeAWS(True)
    fake.policy = False
    with pytest.raises(mod.CandidateError, match='EXISTING_DISTRIBUTION_POLICY_MISSING'):
        mod.run(oac_id=OAC, output=tmp_path / 'artifact', aws=fake)
    assert writes(fake) == []


def test_main_emits_only_closed_summary(monkeypatch, capsys):
    mod = subject()
    summary = {'distribution_id': DIST, 'distribution_arn': 'arn', 'domain': 'domain',
               'status': 'InProgress', 'response_headers_policy_id': POLICY,
               'oac_id': OAC, 'caller_reference': CALLER}
    monkeypatch.setattr(mod, 'run', lambda **kwargs: summary)
    assert mod.main(['--oac-id', OAC, '--output', 'artifact']) == 0
    assert json.loads(capsys.readouterr().out) == summary
    def unexpected(**kwargs):
        raise ValueError('synthetic secret must not leave stderr')
    monkeypatch.setattr(mod, 'run', unexpected)
    assert mod.main(['--oac-id', OAC, '--output', 'artifact']) == 1
    assert capsys.readouterr().err == 'ADMIN_CREATE_FAILED\n'


def test_output_rejects_foreign_files_before_aws(tmp_path):
    mod, fake = subject(), FakeAWS()
    directory = tmp_path / 'artifact'
    directory.mkdir()
    (directory / 'credentials').write_text('private fixture')
    with pytest.raises(mod.CandidateError, match='OUTPUT_DIRECTORY_NOT_EMPTY'):
        mod.run(oac_id=OAC, output=directory, aws=fake)
    assert fake.calls == []


def test_real_cli_uses_arrays_and_suppresses_raw_error(monkeypatch, tmp_path):
    mod = subject()
    result = Mock(returncode=1, stdout='fixture credential', stderr='fixture token')
    runner = Mock(return_value=result)
    monkeypatch.setattr(mod.subprocess, 'run', runner)
    with pytest.raises(mod.CandidateError, match='AWS_OPERATION_FAILED') as caught:
        mod.AWSCLI().call('cloudfront', 'list-distributions', {'MaxItems': '100'})
    assert 'credential' not in str(caught.value) and 'token' not in str(caught.value)
    args, kwargs = runner.call_args
    assert isinstance(args[0], list) and not kwargs.get('shell', False)
    assert '--no-paginate' in args[0] and '--no-cli-pager' in args[0]
    assert '--max-items' not in args[0]  # SDK input, not ambiguous CLI paginator flag.
    assert json.loads(args[0][args[0].index('--cli-input-json') + 1]) == {'MaxItems': '100'}


def test_cli_requires_output_and_oac():
    mod = subject()
    with pytest.raises(SystemExit): mod.main([])

"""Offline CloudFront/OAC installer configuration has a narrow fixed scope."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / 'infra/aws/installer-delivery/distribution.py'
OAC = 'E2EXAMPLEOAC2188'
CALLER = 'installer-2188-20260927-test'
RESPONSE_POLICY = '11111111-1111-4111-8111-111111112188'
ARN = 'arn:aws:cloudfront::218022113852:distribution/E2EXAMPLECF2188'
KEY = 'downloads/ChatFlow-0.4.19-build2188-arm64.apk'
BUCKET = 'starchat-installers-218022113852-sg'


def module():
    assert MODULE.is_file(), 'Offline installer distribution generator is missing'
    spec = importlib.util.spec_from_file_location('installer_distribution_tested', MODULE)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def config():
    return module().distribution_request(oac_id=OAC, caller_reference=CALLER, response_headers_policy_id=RESPONSE_POLICY)['DistributionConfigWithTags']['DistributionConfig']


def test_fixed_origins_group_oac_and_tls():
    data = config()
    origins = data['Origins']
    assert origins['Quantity'] == 2
    s3, hk = origins['Items']
    assert s3['DomainName'] == BUCKET + '.s3.ap-southeast-1.amazonaws.com'
    assert s3['OriginPath'] == '' and hk['OriginPath'] == ''
    assert s3['S3OriginConfig'] == {'OriginAccessIdentity': ''}
    assert s3['OriginAccessControlId'] == OAC
    assert hk['DomainName'] == 'www.liuhetong888.com'
    assert hk['CustomOriginConfig']['OriginProtocolPolicy'] == 'https-only'
    assert hk['CustomOriginConfig']['OriginSslProtocols'] == {'Quantity': 1, 'Items': ['TLSv1.2']}
    assert hk.get('CustomHeaders', {'Quantity': 0}) == {'Quantity': 0}
    groups = data['OriginGroups']
    assert groups['Quantity'] == 1
    group = groups['Items'][0]
    assert group['Members'] == {'Quantity': 2, 'Items': [{'OriginId': s3['Id']}, {'OriginId': hk['Id']}]}
    assert group['FailoverCriteria']['StatusCodes'] == {'Quantity': 4, 'Items': [500, 502, 503, 504]}
    assert 403 not in group['FailoverCriteria']['StatusCodes']['Items']
    assert 404 not in group['FailoverCriteria']['StatusCodes']['Items']


def test_only_exact_immutable_package_is_cacheable_and_default_cannot_fallback():
    data = config()
    assert data['CacheBehaviors']['Quantity'] == 1
    versioned = data['CacheBehaviors']['Items'][0]
    assert versioned['PathPattern'] == KEY and '*' not in versioned['PathPattern']
    assert versioned['CachePolicyId'] == 'b2884449-e4de-46a7-ac36-70bc7f1ddd6d'
    assert versioned['TargetOriginId'] == data['OriginGroups']['Items'][0]['Id']
    default = data['DefaultCacheBehavior']
    assert default['CachePolicyId'] == '4135ea2d-6df8-44a3-9df3-4b5a84be39ad'
    assert default['TargetOriginId'] == data['Origins']['Items'][0]['Id']
    for behavior in (default, versioned):
        assert behavior['AllowedMethods'] == {'Quantity': 2, 'Items': ['GET', 'HEAD'],
                                               'CachedMethods': {'Quantity': 2, 'Items': ['GET', 'HEAD']}}
        assert behavior['ViewerProtocolPolicy'] == 'https-only'
        assert behavior['Compress'] is False
        assert 'OriginRequestPolicyId' not in behavior
        assert behavior.get('ResponseHeadersPolicyId') == (RESPONSE_POLICY if behavior is versioned else None)
        assert 'ForwardedValues' not in behavior
        assert 'RealtimeLogConfigArn' not in behavior
        assert behavior['LambdaFunctionAssociations'] == {'Quantity': 0}
        assert behavior['FunctionAssociations'] == {'Quantity': 0}
    assert 'latest' not in json.dumps(data).lower()


def test_global_pop_no_dns_alias_logs_geo_header_or_custom_certificate():
    data = module().distribution_request(oac_id=OAC, caller_reference=CALLER, response_headers_policy_id=RESPONSE_POLICY)
    config = data['DistributionConfigWithTags']['DistributionConfig']
    assert config['CallerReference'] == CALLER
    assert config['PriceClass'] == 'PriceClass_All'
    assert config['Aliases'] == {'Quantity': 0}
    assert config['ViewerCertificate'] == {'CloudFrontDefaultCertificate': True}
    assert config['Logging'] == {'Enabled': False, 'IncludeCookies': False, 'Bucket': '', 'Prefix': ''}
    assert config['Restrictions'] == {'GeoRestriction': {'RestrictionType': 'none', 'Quantity': 0}}
    assert config['Enabled'] is True
    assert config['HttpVersion'] == 'http2and3'
    assert config['IsIPV6Enabled'] is True
    assert data['DistributionConfigWithTags']['Tags'] == {'Items': [{'Key': 'Project', 'Value': 'StarChatInstallerDelivery'}]}
    out = json.dumps(data).lower()
    assert 'viewer-country' not in out and 'geoip' not in out and 'starchat-media' not in out


def test_oac_signing_config_is_fixed_private_s3_only():
    data = module().oac_request()['OriginAccessControlConfig']
    assert data['SigningProtocol'] == 'sigv4'
    assert data['SigningBehavior'] == 'always'
    assert data['OriginAccessControlOriginType'] == 's3'
    assert data['Name'] == 'StarChatInstallerDeliveryS3'


def test_bucket_policy_allows_only_this_distribution_and_exact_immutable_key():
    data = module().bucket_policy(distribution_arn=ARN)
    assert data['Version'] == '2012-10-17'
    allows = [row for row in data['Statement'] if row['Effect'] == 'Allow']
    assert len(allows) == 1
    allowed = allows[0]
    assert allowed['Principal'] == {'Service': 'cloudfront.amazonaws.com'}
    assert allowed['Action'] == 's3:GetObject'
    assert allowed['Resource'] == 'arn:aws:s3:::' + BUCKET + '/' + KEY
    assert allowed['Condition'] == {'StringEquals': {'AWS:SourceArn': ARN}}
    denies = [row for row in data['Statement'] if row['Effect'] == 'Deny']
    assert len(denies) == 1
    assert denies[0]['Principal'] == '*'
    assert denies[0]['Condition'] == {'Bool': {'aws:SecureTransport': 'false'}}
    assert set(denies[0]['Resource']) == {'arn:aws:s3:::' + BUCKET, 'arn:aws:s3:::' + BUCKET + '/*'}
    assert 'ListBucket' not in json.dumps(data)
    assert 'starchat-media' not in json.dumps(data)


@pytest.mark.parametrize('oac', ['', None, True, 'example', 'E'+('A'*64), 'E1234567\n', 'E123/4567', 'E1234567*'])
def test_invalid_oac_is_rejected_before_rendering(oac):
    with pytest.raises(ValueError):
        module().distribution_request(oac_id=oac, caller_reference=CALLER, response_headers_policy_id=RESPONSE_POLICY)


@pytest.mark.parametrize('caller', ['', None, True, 'a'*129, ' bad', 'x\n', 'x/other', 'x;delete', '你好'])
def test_invalid_caller_reference_is_rejected(caller):
    with pytest.raises(ValueError):
        module().distribution_request(oac_id=OAC, caller_reference=caller, response_headers_policy_id=RESPONSE_POLICY)


@pytest.mark.parametrize('arn', ['', None, True, ARN.replace('218022113852', '999999999999'),
                               ARN.replace('aws:', 'aws-cn:'), ARN+'*', ARN+'\n',
                               'arn:aws:cloudfront::218022113852:distribution/*'])
def test_other_account_wildcards_and_invalid_arns_are_rejected(arn):
    with pytest.raises(ValueError):
        module().bucket_policy(distribution_arn=arn)


def test_render_is_fresh_deterministic_and_cli_does_not_make_network_calls(tmp_path):
    first = module().distribution_request(oac_id=OAC, caller_reference=CALLER, response_headers_policy_id=RESPONSE_POLICY)
    second = module().distribution_request(oac_id=OAC, caller_reference=CALLER, response_headers_policy_id=RESPONSE_POLICY)
    assert first == second
    first['DistributionConfigWithTags']['DistributionConfig']['Origins']['Items'][0]['DomainName'] = 'evil.invalid'
    assert module().distribution_request(oac_id=OAC, caller_reference=CALLER, response_headers_policy_id=RESPONSE_POLICY) == second
    process = subprocess.run([sys.executable, str(MODULE), 'distribution', '--oac-id', OAC,
                              '--caller-reference', CALLER, '--response-headers-policy-id', RESPONSE_POLICY], capture_output=True, text=True, timeout=10)
    assert process.returncode == 0
    assert json.loads(process.stdout) == second
    assert process.stderr == ''


def test_cli_rejects_arbitrary_origin_and_invalid_ids_without_partial_json():
    source = module()
    for args in (
        ['distribution', '--oac-id', 'E1234567*', '--caller-reference', CALLER, '--response-headers-policy-id', RESPONSE_POLICY],
        ['distribution', '--oac-id', OAC, '--caller-reference', CALLER, '--response-headers-policy-id', RESPONSE_POLICY, '--origin', 'evil.invalid'],
        ['bucket-policy', '--distribution-arn', ARN.replace('218022113852', '999999999999')],
    ):
        process = subprocess.run([sys.executable, str(MODULE), *args], capture_output=True, text=True, timeout=10)
        assert process.returncode == 2
        assert process.stdout == ''
    assert source.HONG_KONG_ORIGIN == 'www.liuhetong888.com'


def test_cors_policy_only_allows_fixed_www_range_with_no_credentials():
    data = module().response_headers_request()['ResponseHeadersPolicyConfig']
    assert data['Name'] == 'StarChatInstallerRange2188'
    cors = data['CorsConfig']
    assert cors['AccessControlAllowOrigins'] == {'Quantity': 1, 'Items': ['https://www.liuhetong888.com']}
    assert cors['AccessControlAllowCredentials'] is False
    assert cors['AccessControlAllowMethods'] == {'Quantity': 2, 'Items': ['GET', 'HEAD']}
    assert cors['AccessControlAllowHeaders'] == {'Quantity': 1, 'Items': ['Range']}
    assert cors['AccessControlExposeHeaders'] == {'Quantity': 3, 'Items': ['Content-Range', 'Content-Length', 'Accept-Ranges']}
    assert cors['OriginOverride'] is True
    assert '*' not in json.dumps(data) and 'Cookie' not in json.dumps(data)


@pytest.mark.parametrize('policy_id', ['', None, True, 'policy', '*',
                                      RESPONSE_POLICY+'\n', RESPONSE_POLICY.replace('1', 'A', 1),
                                      RESPONSE_POLICY.replace('-', ''), 'x'*36])
def test_response_policy_requires_a_bounded_real_uuid(policy_id):
    with pytest.raises(ValueError):
        module().distribution_request(oac_id=OAC, caller_reference=CALLER, response_headers_policy_id=policy_id)


def test_response_policy_id_is_not_optional():
    with pytest.raises(TypeError):
        module().distribution_request(oac_id=OAC, caller_reference=CALLER)

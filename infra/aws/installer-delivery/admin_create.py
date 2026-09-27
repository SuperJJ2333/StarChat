"""One administrator-only CloudShell creation/resume for installer build 2188.

Run beside distribution.py with --oac-id E6P1PEF2BA7OK --output <artifact-dir>.
This executes AWS CLI only when run(). No IAM, S3, DNS or update/delete calls.
Only sanitized summary fields leave stdout; raw AWS output is never saved.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import distribution


CALLER_REFERENCE = 'starchat-installer-2188-20260927'
APPROVED_OAC_ID = 'E6P1PEF2BA7OK'
ACCOUNT = distribution.ACCOUNT_ID
BUCKET_DOMAIN = distribution.BUCKET + '.s3.' + distribution.REGION + '.amazonaws.com'
FILES = {'response-headers-request.json', 'distribution-request.json', 'summary.json'}
UUID = r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
CF_ID = r'E[A-Z0-9]{7,63}'


class CandidateError(RuntimeError):
    """Fixed non-sensitive failure categories; do not embed AWS response text."""


class AWSCLI:
    def call(self, service, operation, request=None, request_file=None):
        args = ['aws', service, operation, '--region', distribution.REGION,
                '--output', 'json', '--no-cli-pager', '--no-paginate']
        if request_file is not None:
            args += ['--cli-input-json', 'file://' + str(request_file)]
        elif request is not None:
            args += ['--cli-input-json', json.dumps(request, separators=(',', ':'))]
        try:
            completed = subprocess.run(args, capture_output=True, text=True,
                encoding='utf-8', timeout=120, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise CandidateError('AWS_OPERATION_FAILED: ' + operation) from None
        if completed.returncode != 0:
            raise CandidateError('AWS_OPERATION_FAILED: ' + operation)
        try:
            result = json.loads(completed.stdout)
        except (ValueError, TypeError):
            raise CandidateError('AWS_RESPONSE_INVALID: ' + operation) from None
        if not isinstance(result, dict):
            raise CandidateError('AWS_RESPONSE_INVALID: ' + operation)
        return result


def _identifier(value, pattern):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        raise CandidateError('AWS_RESOURCE_ID_INVALID')
    return value


def _output_directory(output):
    path = Path(output)
    if any(part.is_symlink() for part in [path, *path.parents]):
        raise CandidateError('OUTPUT_SYMLINK_FORBIDDEN')
    if path.exists():
        if not path.is_dir() or any(item.name not in FILES or not item.is_file()
                                  or item.is_symlink() for item in path.iterdir()):
            raise CandidateError('OUTPUT_DIRECTORY_NOT_EMPTY')
    else:
        path.mkdir(parents=True, mode=0o700)
    return path.resolve()


def _save(directory, name, payload, *, replace_summary=False):
    path = directory / name
    text = json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + '\n'
    if path.exists():
        try:
            prior = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            raise CandidateError('ARTIFACT_CONFLICT') from None
        if prior == payload:
            return path
        if not replace_summary:
            raise CandidateError('ARTIFACT_CONFLICT')
    # Fixed filenames only. Exclusive temporary file avoids following symlinks.
    temporary = directory / (name + '.tmp')
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8', newline='\n') as stream:
            stream.write(text)
        os.replace(temporary, path)
    except OSError:
        raise CandidateError('ARTIFACT_WRITE_FAILED') from None
    return path


def _inventory(aws, operation, wrapper, request=None):
    marker, seen = None, set()
    for _ in range(100):
        query = dict(request or {})
        query['MaxItems'] = '100'
        if marker is not None:
            query['Marker'] = marker
        response = aws.call('cloudfront', operation, query)
        page = response.get(wrapper)
        if not isinstance(page, dict):
            raise CandidateError('AWS_INVENTORY_INVALID')
        items = page.get('Items', [])
        if not isinstance(items, list) or not all(isinstance(item, dict) for item in items):
            raise CandidateError('AWS_INVENTORY_INVALID')
        yield from items
        marker = page.get('NextMarker')
        if not marker:
            if page.get('IsTruncated', False):
                raise CandidateError('INVALID_PAGINATION')
            return
        if not isinstance(marker, str) or marker in seen or len(marker) > 2048:
            raise CandidateError('INVALID_PAGINATION')
        seen.add(marker)
    raise CandidateError('INVENTORY_LIMIT_EXCEEDED')


def _compatible(actual, expected, path=()):
    """Exact request values plus finite, observed AWS response normalization.

    Origins bind by unique Id, while origin-group Members remain ordered.
    Only GET/HEAD method lists are unordered; all other lists stay positional.
    """
    defaults = {}
    if not path:
        defaults = {'WebACLId': '', 'Staging': False, 'DefaultRootObject': '',
                    'CustomErrorResponses': {'Quantity': 0},
                    'ContinuousDeploymentPolicyId': '', 'AnycastIpListId': '',
                    'ConnectionMode': 'direct'}
    elif path == ('ViewerCertificate',):
        defaults = {'MinimumProtocolVersion': 'TLSv1', 'SSLSupportMethod': 'vip',
                    'CertificateSource': 'cloudfront', 'Certificate': '',
                    'IAMCertificateId': '', 'ACMCertificateArn': ''}
    elif path == ('DefaultCacheBehavior',) or path == ('CacheBehaviors', 'Items', '*'):
        defaults = {'FieldLevelEncryptionId': '', 'SmoothStreaming': False,
                    'RealtimeLogConfigArn': '', 'GrpcConfig': {'Enabled': False}}
    elif path == ('Origins', 'Items', '*'):
        defaults = {'OriginShield': {'Enabled': False}, 'OriginAccessControlId': ''}
    elif path == ('Origins', 'Items', '*', 'S3OriginConfig'):
        defaults = {'OriginReadTimeout': 30}
    elif path == ('OriginGroups', 'Items', '*'):
        defaults = {'SelectionCriteria': 'default'}
    if isinstance(expected, dict):
        if not isinstance(actual, dict) or not expected.keys() <= actual.keys():
            return False
        for key in actual.keys() - expected.keys():
            if key not in defaults or not _compatible(actual[key], defaults[key], path + (key,)):
                return False
        return all(_compatible(actual[key], value, path + (key,))
                   for key, value in expected.items())
    if isinstance(expected, list):
        if not isinstance(actual, list) or len(actual) != len(expected):
            return False
        if path == ('Origins', 'Items'):
            if not all(isinstance(item, dict) and isinstance(item.get('Id'), str)
                       for item in actual + expected):
                return False
            actual_by_id = {item['Id']: item for item in actual}
            expected_by_id = {item['Id']: item for item in expected}
            if (len(actual_by_id) != len(actual) or len(expected_by_id) != len(expected)
                    or actual_by_id.keys() != expected_by_id.keys()):
                return False
            return all(_compatible(actual_by_id[key], value, path + ('*',))
                       for key, value in expected_by_id.items())
        method_paths = {
            prefix + suffix
            for prefix in [('DefaultCacheBehavior',), ('CacheBehaviors', 'Items', '*')]
            for suffix in [('AllowedMethods', 'Items'), ('AllowedMethods', 'CachedMethods', 'Items')]
        }
        if path in method_paths:
            return (len(actual) == len(expected) == 2
                    and all(isinstance(item, str) for item in actual + expected)
                    and set(actual) == set(expected) == {'GET', 'HEAD'})
        return all(_compatible(a, e, path + ('*',)) for a, e in zip(actual, expected))
    return type(actual) is type(expected) and actual == expected


def _distribution_candidates(aws):
    result = []
    expected_comment = distribution.distribution_request(oac_id=APPROVED_OAC_ID,
        caller_reference=CALLER_REFERENCE, response_headers_policy_id='11111111-1111-4111-8111-111111112188')[
            'DistributionConfigWithTags']['DistributionConfig']['Comment']
    for item in _inventory(aws, 'list-distributions', 'DistributionList'):
        origins = item.get('Origins', {}).get('Items', [])
        if any(origin.get('DomainName') == BUCKET_DOMAIN for origin in origins) or item.get('Comment') == expected_comment:
            identifier = _identifier(item.get('Id'), CF_ID)
            config = aws.call('cloudfront', 'get-distribution-config', {'Id': identifier}).get('DistributionConfig')
            if not isinstance(config, dict) or config.get('CallerReference') != CALLER_REFERENCE:
                raise CandidateError('DISTRIBUTION_IDENTITY_CONFLICT')
            tags = aws.call('cloudfront', 'list-tags-for-resource', {
                'Resource': f'arn:aws:cloudfront::{ACCOUNT}:distribution/{identifier}'}).get('Tags')
            if tags != {'Items': [{'Key': 'Project', 'Value': distribution.PROJECT_TAG}]}:
                raise CandidateError('DISTRIBUTION_TAG_MISMATCH')
            result.append((identifier, config))
    if len(result) > 1:
        raise CandidateError('DUPLICATE_DISTRIBUTION')
    return result


def _validate_distribution(aws, identifier, expected):
    config = aws.call('cloudfront', 'get-distribution-config', {'Id': identifier}).get('DistributionConfig')
    if not _compatible(config, expected):
        raise CandidateError('DISTRIBUTION_CONFIG_MISMATCH')
    tags = aws.call('cloudfront', 'list-tags-for-resource', {
        'Resource': f'arn:aws:cloudfront::{ACCOUNT}:distribution/{identifier}'}).get('Tags')
    if tags != {'Items': [{'Key': 'Project', 'Value': distribution.PROJECT_TAG}]}:
        raise CandidateError('DISTRIBUTION_TAG_MISMATCH')


def run(*, oac_id, output, aws=None):
    if oac_id != APPROVED_OAC_ID:
        raise CandidateError('APPROVED_OAC_REQUIRED')
    directory = _output_directory(output)
    aws = aws or AWSCLI()
    identity = aws.call('sts', 'get-caller-identity')
    if identity.get('Account') != ACCOUNT:
        raise CandidateError('ACCOUNT_MISMATCH')
    arn = identity.get('Arn')
    if not isinstance(arn, str) or not re.fullmatch(r'arn:aws:(iam|sts)::' + ACCOUNT + r':.+', arn):
        raise CandidateError('IDENTITY_INVALID')
    if re.search(r'(?:assumed-role|role)/(?:[^/]+/)*StarChatSgMaintenanceRole(?:/|$)', arn):
        raise CandidateError('ADMINISTRATOR_SESSION_REQUIRED')
    oac = aws.call('cloudfront', 'get-origin-access-control-config', {'Id': oac_id})
    if oac.get('OriginAccessControlConfig') != distribution.oac_request()['OriginAccessControlConfig']:
        raise CandidateError('OAC_CONFIG_MISMATCH')
    expected_policy = distribution.response_headers_request()
    policies = []
    for item in _inventory(aws, 'list-response-headers-policies', 'ResponseHeadersPolicyList', {'Type': 'custom'}):
        policy = item.get('ResponseHeadersPolicy', {})
        if policy.get('ResponseHeadersPolicyConfig', {}).get('Name') == expected_policy['ResponseHeadersPolicyConfig']['Name']:
            identifier = _identifier(policy.get('Id'), UUID)
            config = aws.call('cloudfront', 'get-response-headers-policy-config', {'Id': identifier})
            if config.get('ResponseHeadersPolicyConfig') != expected_policy['ResponseHeadersPolicyConfig']:
                raise CandidateError('RESPONSE_HEADERS_CONFIG_MISMATCH')
            policies.append(identifier)
    if len(policies) > 1:
        raise CandidateError('DUPLICATE_RESPONSE_HEADERS_POLICY')
    candidates = _distribution_candidates(aws)
    if candidates and not policies:
        raise CandidateError('EXISTING_DISTRIBUTION_POLICY_MISSING')
    if not policies:
        path = _save(directory, 'response-headers-request.json', expected_policy)
        response = aws.call('cloudfront', 'create-response-headers-policy', request_file=path)
        policy_id = _identifier(response.get('ResponseHeadersPolicy', {}).get('Id'), UUID)
        actual = aws.call('cloudfront', 'get-response-headers-policy-config', {'Id': policy_id})
        if actual.get('ResponseHeadersPolicyConfig') != expected_policy['ResponseHeadersPolicyConfig']:
            raise CandidateError('RESPONSE_HEADERS_CONFIG_MISMATCH')
    else:
        policy_id = policies[0]
    request = distribution.distribution_request(oac_id=oac_id,
        caller_reference=CALLER_REFERENCE, response_headers_policy_id=policy_id)
    expected = request['DistributionConfigWithTags']['DistributionConfig']
    if candidates:
        identifier, actual = candidates[0]
        if not _compatible(actual, expected):
            raise CandidateError('DISTRIBUTION_CONFIG_MISMATCH')
    else:
        path = _save(directory, 'distribution-request.json', request)
        response = aws.call('cloudfront', 'create-distribution-with-tags', request_file=path)
        identifier = _identifier(response.get('Distribution', {}).get('Id'), CF_ID)
    _validate_distribution(aws, identifier, expected)
    result = aws.call('cloudfront', 'get-distribution', {'Id': identifier}).get('Distribution', {})
    if result.get('Id') != identifier or result.get('ARN') != f'arn:aws:cloudfront::{ACCOUNT}:distribution/{identifier}':
        raise CandidateError('DISTRIBUTION_IDENTITY_CONFLICT')
    domain = _identifier(result.get('DomainName'), r'd[a-z0-9]{1,63}\.cloudfront\.net')
    status = result.get('Status')
    if status not in {'InProgress', 'Deployed'}:
        raise CandidateError('DISTRIBUTION_STATUS_INVALID')
    summary = {'distribution_id': identifier, 'distribution_arn': result['ARN'],
        'domain': domain, 'status': status, 'response_headers_policy_id': policy_id,
        'oac_id': oac_id, 'caller_reference': CALLER_REFERENCE}
    _save(directory, 'summary.json', summary, replace_summary=True)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--oac-id', required=True)
    parser.add_argument('--output', required=True, help='New or resumed dedicated local artifact directory')
    arguments = parser.parse_args(argv)
    try:
        summary = run(oac_id=arguments.oac_id, output=arguments.output)
    except CandidateError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception:
        print('ADMIN_CREATE_FAILED', file=sys.stderr)
        return 1
    print(json.dumps(summary, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

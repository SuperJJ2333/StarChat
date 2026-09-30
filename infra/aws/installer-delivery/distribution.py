"""Pure local AWS CLI inputs for the one approved immutable Android installer.

No AWS SDK, credentials, network call, upload, DNS or deployment is performed.
The OAC ID and distribution ARN must be read back from actual cloud resources
before deployment; local JSON generation does not prove those resources exist.
"""
import argparse
import json
import re


ACCOUNT_ID = '218022113852'
REGION = 'ap-southeast-1'
BUCKET = 'starchat-installers-218022113852-sg'
INSTALLER_KEY = 'downloads/ChatFlow-0.4.19-build2188-arm64.apk'
HONG_KONG_ORIGIN = 'www.liuhetong888.com'
PROJECT_TAG = 'StarChatInstallerDelivery'
# AWS managed policies: no cookies, query strings, headers or compression keys.
CACHING_DISABLED = '4135ea2d-6df8-44a3-9df3-4b5a84be39ad'
CACHING_UNCOMPRESSED = 'b2884449-e4de-46a7-ac36-70bc7f1ddd6d'


def _validated(value, pattern, label):
    if not isinstance(value, str) or re.fullmatch(pattern, value) is None:
        # Do not echo an arbitrary caller value in an error message.
        raise ValueError('Invalid ' + label)
    return value


def _behavior(target_origin, cache_policy):
    return {
        'TargetOriginId': target_origin,
        'ViewerProtocolPolicy': 'https-only',
        'AllowedMethods': {'Quantity': 2, 'Items': ['GET', 'HEAD'],
                           'CachedMethods': {'Quantity': 2, 'Items': ['GET', 'HEAD']}},
        'CachePolicyId': cache_policy,
        'Compress': False,
        'LambdaFunctionAssociations': {'Quantity': 0},
        'FunctionAssociations': {'Quantity': 0},
        'TrustedSigners': {'Enabled': False, 'Quantity': 0},
        'TrustedKeyGroups': {'Enabled': False, 'Quantity': 0},
    }


def oac_request():
    """Input for create-origin-access-control; never access a media bucket."""
    return {'OriginAccessControlConfig': {
        'Name': 'StarChatInstallerDeliveryS3',
        'Description': 'Read only the approved immutable Android installer',
        'SigningProtocol': 'sigv4',
        'SigningBehavior': 'always',
        'OriginAccessControlOriginType': 's3',
    }}


def response_headers_request():
    """Input for create-response-headers-policy for the fixed Range probe site."""
    return {'ResponseHeadersPolicyConfig': {
        'Name': 'StarChatInstallerRange2188',
        'Comment': 'Bounded installer Range probes from the existing website',
        'CorsConfig': {
            'AccessControlAllowOrigins': {'Quantity': 1, 'Items': ['https://www.liuhetong888.com']},
            'AccessControlAllowCredentials': False,
            'AccessControlAllowMethods': {'Quantity': 2, 'Items': ['GET', 'HEAD']},
            'AccessControlAllowHeaders': {'Quantity': 1, 'Items': ['Range']},
            'AccessControlExposeHeaders': {'Quantity': 3, 'Items': ['Content-Range', 'Content-Length', 'Accept-Ranges']},
            'OriginOverride': True,
        },
    }}


def distribution_request(*, oac_id, caller_reference, response_headers_policy_id):
    """Input for create-distribution-with-tags using the AWS-assigned domain.

    CloudFront chooses POPs using its network routing. This configuration does
    not select a user's country or guarantee the fastest end-user route.
    """
    _validated(oac_id, r'E[A-Z0-9]{7,63}', 'OAC ID')
    _validated(caller_reference, r'[A-Za-z0-9][A-Za-z0-9_.-]{0,127}', 'caller reference')
    _validated(response_headers_policy_id, r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
               'response headers policy ID')
    s3_id, hk_id, group_id = 'installer-s3', 'installer-hong-kong', 'installer-failover'
    versioned = _behavior(group_id, CACHING_UNCOMPRESSED)
    versioned['PathPattern'] = INSTALLER_KEY
    versioned['ResponseHeadersPolicyId'] = response_headers_policy_id
    config = {
        'CallerReference': caller_reference,
        'Comment': 'Immutable Android installer with S3 OAC and Hong Kong origin fallback',
        'Enabled': True,
        'Aliases': {'Quantity': 0},
        'Origins': {'Quantity': 2, 'Items': [
            {'Id': s3_id, 'DomainName': BUCKET + '.s3.' + REGION + '.amazonaws.com',
             'OriginPath': '', 'CustomHeaders': {'Quantity': 0},
             'S3OriginConfig': {'OriginAccessIdentity': ''}, 'OriginAccessControlId': oac_id,
             'ConnectionAttempts': 1, 'ConnectionTimeout': 3},
            {'Id': hk_id, 'DomainName': HONG_KONG_ORIGIN, 'OriginPath': '',
             'CustomHeaders': {'Quantity': 0}, 'ConnectionAttempts': 1, 'ConnectionTimeout': 3,
             'CustomOriginConfig': {'HTTPPort': 80, 'HTTPSPort': 443,
                 'OriginProtocolPolicy': 'https-only',
                 'OriginSslProtocols': {'Quantity': 1, 'Items': ['TLSv1.2']},
                 'OriginReadTimeout': 30, 'OriginKeepaliveTimeout': 5}},
        ]},
        'OriginGroups': {'Quantity': 1, 'Items': [
            {'Id': group_id,
             'FailoverCriteria': {'StatusCodes': {'Quantity': 4, 'Items': [500, 502, 503, 504]}},
             'Members': {'Quantity': 2, 'Items': [{'OriginId': s3_id}, {'OriginId': hk_id}]}},
        ]},
        # Unknown keys go to private S3 without origin failover. Only the exact
        # approved APK key below is cacheable and can use the Hong Kong origin.
        'DefaultCacheBehavior': _behavior(s3_id, CACHING_DISABLED),
        'CacheBehaviors': {'Quantity': 1, 'Items': [versioned]},
        'Logging': {'Enabled': False, 'IncludeCookies': False, 'Bucket': '', 'Prefix': ''},
        'PriceClass': 'PriceClass_All',
        'ViewerCertificate': {'CloudFrontDefaultCertificate': True},
        'Restrictions': {'GeoRestriction': {'RestrictionType': 'none', 'Quantity': 0}},
        'HttpVersion': 'http2and3',
        'IsIPV6Enabled': True,
    }
    return {'DistributionConfigWithTags': {'DistributionConfig': config,
            'Tags': {'Items': [{'Key': 'Project', 'Value': PROJECT_TAG}]}}}


def bucket_policy(*, distribution_arn):
    """Policy for only the new installer bucket and actual account distribution.

    All public-access-block settings must stay enabled separately. This policy
    grants no listing, write, media access or mutable/latest object permission.
    """
    _validated(distribution_arn, r'arn:aws:cloudfront::' + ACCOUNT_ID + r':distribution/E[A-Z0-9]{7,63}',
               'distribution ARN')
    bucket_arn = 'arn:aws:s3:::' + BUCKET
    return {'Version': '2012-10-17', 'Statement': [
        {'Sid': 'DenyInsecureTransport', 'Effect': 'Deny', 'Principal': '*',
         'Action': 's3:*', 'Resource': [bucket_arn, bucket_arn + '/*'],
         'Condition': {'Bool': {'aws:SecureTransport': 'false'}}},
        {'Sid': 'AllowOnlyApprovedInstallerDistribution', 'Effect': 'Allow',
         'Principal': {'Service': 'cloudfront.amazonaws.com'}, 'Action': 's3:GetObject',
         'Resource': bucket_arn + '/' + INSTALLER_KEY,
         'Condition': {'StringEquals': {'AWS:SourceArn': distribution_arn}}},
    ]}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='kind', required=True)
    distribution = commands.add_parser('distribution', help='Print CreateDistributionWithTags JSON')
    distribution.add_argument('--oac-id', required=True)
    distribution.add_argument('--caller-reference', required=True)
    distribution.add_argument('--response-headers-policy-id', required=True)
    commands.add_parser('oac', help='Print CreateOriginAccessControl JSON')
    commands.add_parser('response-headers', help='Print CreateResponseHeadersPolicy JSON')
    policy = commands.add_parser('bucket-policy', help='Print the exact installer bucket policy')
    policy.add_argument('--distribution-arn', required=True)
    args = parser.parse_args(argv)
    try:
        if args.kind == 'distribution':
            payload = distribution_request(oac_id=args.oac_id, caller_reference=args.caller_reference,
                                           response_headers_policy_id=args.response_headers_policy_id)
        elif args.kind == 'oac':
            payload = oac_request()
        elif args.kind == 'response-headers':
            payload = response_headers_request()
        else:
            payload = bucket_policy(distribution_arn=args.distribution_arn)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

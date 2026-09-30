"""Local candidate boundary checks, not an effective-role/IAM simulation."""
from fnmatch import fnmatchcase
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / 'infra/aws/installer-delivery/maintenance-policy.json'
BUCKET = 'arn:aws:s3:::starchat-installers-218022113852-sg'
DIST = 'arn:aws:cloudfront::218022113852:distribution/E30IR8IHK6PMXZ'
OAC = 'arn:aws:cloudfront::218022113852:origin-access-control/E6P1PEF2BA7OK'
TAG = {'aws:ResourceTag/Project': 'StarChatInstallerDelivery'}
BUCKET_ACTIONS = {'s3:GetBucketLocation','s3:GetBucketOwnershipControls','s3:GetBucketPolicy',
                  's3:PutBucketPolicy','s3:GetBucketPublicAccessBlock','s3:GetBucketVersioning',
                  's3:GetEncryptionConfiguration','s3:GetBucketTagging'}
DIST_ACTIONS = {'cloudfront:GetDistribution','cloudfront:GetDistributionConfig',
                'cloudfront:ListTagsForResource','cloudfront:UpdateDistribution'}
OAC_ACTIONS = {'cloudfront:GetOriginAccessControl','cloudfront:GetOriginAccessControlConfig'}


def load():
    assert POLICY.is_file(), 'installer exact-ID maintenance candidate is missing'
    return json.loads(POLICY.read_text(encoding='utf-8'))


def values(value):
    return value if isinstance(value,list) else [value]


def allowed(policy,action,resource,**context):
    for statement in policy['Statement']:
        if statement['Effect']!='Allow' or action not in values(statement['Action']):continue
        if not any(fnmatchcase(resource,pattern) for pattern in values(statement['Resource'])):continue
        conditions=statement.get('Condition',{})
        matched=True
        for operator,entries in conditions.items():
            for key,expected in entries.items():
                if operator=='StringEquals':matched &= context.get(key)==expected
                elif operator=='StringLike':matched &= key in context and fnmatchcase(context[key],expected)
                else:raise AssertionError('unexpected IAM condition subset')
        if matched:return True
    return False


def test_only_explicit_required_maintenance_actions():
    policy=load()
    assert policy['Version']=='2012-10-17'
    assert {action for statement in policy['Statement'] for action in values(statement['Action'])} == (
        BUCKET_ACTIONS|DIST_ACTIONS|OAC_ACTIONS|{'s3:ListBucket','s3:GetObject','s3:PutObject','cloudfront:ListDistributions'})
    assert all(statement['Effect']=='Allow' and 'NotAction' not in statement and 'NotResource' not in statement
               for statement in policy['Statement'])
    assert all('*' not in action for statement in policy['Statement'] for action in values(statement['Action']))


def test_wildcard_resource_is_only_readonly_distribution_inventory():
    wildcard=[s for s in load()['Statement'] if '*' in values(s['Resource'])]
    assert len(wildcard)==1
    assert values(wildcard[0]['Action'])==['cloudfront:ListDistributions']


@pytest.mark.parametrize('action',sorted(BUCKET_ACTIONS))
def test_bucket_config_is_exact_installer_bucket(action):
    policy=load();assert allowed(policy,action,BUCKET)
    for other in ('arn:aws:s3:::starchat-media-218022113852-sg','arn:aws:s3:::another',BUCKET+'/downloads/file'):
        assert not allowed(policy,action,other)


@pytest.mark.parametrize('prefix',['downloads/','downloads/ChatFlow','downloads/future/'])
def test_prefix_list_allowed(prefix):
    assert allowed(load(),'s3:ListBucket',BUCKET,**{'s3:prefix':prefix})


@pytest.mark.parametrize('prefix',[None,'','downloads','media/','business/','synapse/','downloads-other/'])
def test_other_prefix_list_denied(prefix):
    context={} if prefix is None else {'s3:prefix':prefix}
    assert not allowed(load(),'s3:ListBucket',BUCKET,**context)


@pytest.mark.parametrize('action',['s3:GetObject','s3:PutObject'])
def test_only_download_objects_in_exact_bucket(action):
    policy=load()
    for key in ('downloads/ChatFlow-0.4.19-build2188-arm64.apk','downloads/ChatFlow-future.apk'):
        assert allowed(policy,action,BUCKET+'/'+key)
    for other in (BUCKET+'/media/file',BUCKET+'/business/file',BUCKET+'/synapse/file',BUCKET+'/downloads-other/file',
                  'arn:aws:s3:::starchat-media-218022113852-sg/downloads/file'):
        assert not allowed(policy,action,other)


@pytest.mark.parametrize('action',sorted(DIST_ACTIONS))
def test_only_actual_installer_distribution_with_existing_project_tag(action):
    policy=load();assert allowed(policy,action,DIST,**TAG)
    for other in ('arn:aws:cloudfront::218022113852:distribution/E11LA69ZDOD790',
                  'arn:aws:cloudfront::218022113852:distribution/FUTURE',
                  'arn:aws:cloudfront::999999999999:distribution/E30IR8IHK6PMXZ'):
        assert not allowed(policy,action,other,**TAG)
    assert not allowed(policy,action,DIST)
    assert not allowed(policy,action,DIST,**{'aws:ResourceTag/Project':'Another'})


@pytest.mark.parametrize('action',sorted(OAC_ACTIONS))
def test_only_actual_oac_read(action):
    policy=load();assert allowed(policy,action,OAC)
    assert not allowed(policy,action,'arn:aws:cloudfront::218022113852:origin-access-control/E22ESWGK3JHN50')
    assert not allowed(policy,action,'arn:aws:cloudfront::999999999999:origin-access-control/E6P1PEF2BA7OK')


@pytest.mark.parametrize('action,resource',[
    ('s3:CreateBucket',BUCKET),('s3:PutEncryptionConfiguration',BUCKET),
    ('s3:PutBucketVersioning',BUCKET),('s3:PutBucketPublicAccessBlock',BUCKET),
    ('s3:PutBucketTagging',BUCKET),('s3:PutBucketOwnershipControls',BUCKET),
    ('s3:DeleteBucket',BUCKET),('s3:DeleteBucketPolicy',BUCKET),('s3:DeleteObject',BUCKET+'/downloads/file'),
    ('s3:DeleteObjectVersion',BUCKET+'/downloads/file'),('s3:PutObjectAcl',BUCKET+'/downloads/file'),
    ('s3:PutBucketAcl',BUCKET),('s3:PutAccountPublicAccessBlock','*'),('s3:ListAllMyBuckets','*'),
    ('cloudfront:CreateOriginAccessControl','*'),('cloudfront:CreateDistribution','*'),
    ('cloudfront:UpdateOriginAccessControl',OAC),('cloudfront:DeleteOriginAccessControl',OAC),
    ('cloudfront:DeleteDistribution',DIST),('cloudfront:TagResource',DIST),('cloudfront:UntagResource',DIST),
    ('cloudfront:CreateInvalidation',DIST),('cloudfront:CreateResponseHeadersPolicy','*'),
    ('cloudfront:GetResponseHeadersPolicy','*'),('cloudfront:UpdateResponseHeadersPolicy','*'),
    ('cloudfront:ListOriginAccessControls','*'),('iam:PutRolePolicy','*'),('iam:PassRole','*'),
    ('route53:ChangeResourceRecordSets','*'),
])
def test_no_initialization_or_unrelated_mutations(action,resource):
    assert not allowed(load(),action,resource,**TAG,**{'s3:LocationConstraint':'ap-southeast-1'})

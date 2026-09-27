"""Local permission boundaries for the installer delivery bootstrap candidate.

These checks validate this supplemental policy, not the role's effective policy
or AWS authorization. No AWS calls or credentials are used.
"""

from fnmatch import fnmatchcase
import json
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "infra/aws/installer-delivery/bootstrap-policy.json"
BUCKET = "arn:aws:s3:::starchat-installers-218022113852-sg"
OBJECT = BUCKET + "/downloads/ChatFlow-0.4.19-build2188-arm64.apk"
DISTRIBUTION = "arn:aws:cloudfront::218022113852:distribution/EXAMPLE"
PROJECT = "StarChatInstallerDelivery"
BUCKET_ACTIONS = {
    "s3:GetBucketLocation",
    "s3:GetBucketOwnershipControls",
    "s3:GetBucketPolicy",
    "s3:PutBucketPolicy",
    "s3:GetBucketPublicAccessBlock",
    "s3:PutBucketPublicAccessBlock",
    "s3:GetBucketVersioning",
    "s3:PutBucketVersioning",
    "s3:GetEncryptionConfiguration",
    "s3:PutEncryptionConfiguration",
    "s3:GetBucketTagging",
    "s3:PutBucketTagging",
}
CF_ACTIONS = {
    "cloudfront:ListDistributions",
    "cloudfront:ListOriginAccessControls",
    "cloudfront:GetOriginAccessControl",
    "cloudfront:GetOriginAccessControlConfig",
    "cloudfront:CreateOriginAccessControl",
    "cloudfront:ListTagsForResource",
    "cloudfront:GetDistribution",
    "cloudfront:GetDistributionConfig",
    "cloudfront:UpdateDistribution",
}


def load_policy():
    assert POLICY.is_file(), "installer bootstrap policy candidate is missing"
    return json.loads(POLICY.read_text(encoding="utf-8"))


def values(value):
    return value if isinstance(value, list) else [value]


def statements_for(policy, action):
    return [statement for statement in policy["Statement"]
            if action in values(statement["Action"])]


def conditions_match(conditions, context):
    """Evaluate only the candidate's tested IAM condition subset, fail closed."""
    for operator, entries in conditions.items():
        for key, expected in entries.items():
            if key not in context:
                return False
            actual = values(context[key])
            expected = values(expected)
            if operator == "StringEquals":
                match = any(item in expected for item in actual)
            elif operator == "StringLike":
                match = any(fnmatchcase(item, pattern)
                            for item in actual for pattern in expected)
            elif operator == "ForAllValues:StringEquals":
                match = all(item in expected for item in actual)
            else:
                raise AssertionError(f"untested IAM operator: {operator}")
            if not match:
                return False
    return True


def allowed(policy, action, resource, **context):
    return any(statement["Effect"] == "Allow"
               and any(fnmatchcase(resource, pattern)
                       for pattern in values(statement["Resource"]))
               and conditions_match(statement.get("Condition", {}), context)
               for statement in statements_for(policy, action))


def test_candidate_has_only_explicit_required_actions():
    policy = load_policy()
    assert policy["Version"] == "2012-10-17"
    actions = {action for statement in policy["Statement"]
               for action in values(statement["Action"])}
    assert actions == BUCKET_ACTIONS | CF_ACTIONS | {
        "s3:CreateBucket", "s3:ListBucket", "s3:PutObject", "s3:GetObject"
    }
    assert all(statement["Effect"] == "Allow" for statement in policy["Statement"])
    assert all("NotAction" not in statement and "NotResource" not in statement
               for statement in policy["Statement"])


def test_all_s3_resources_are_the_unique_installer_bucket():
    policy = load_policy()
    for statement in policy["Statement"]:
        if any(action.startswith("s3:") for action in values(statement["Action"])):
            assert set(values(statement["Resource"])) <= {BUCKET, BUCKET + "/downloads/*"}


@pytest.mark.parametrize("region", ["us-east-1", "ap-east-1", "eu-west-1", None])
def test_bucket_creation_requires_singapore(region):
    policy = load_policy()
    assert allowed(policy, "s3:CreateBucket", BUCKET,
                   **{"s3:LocationConstraint": "ap-southeast-1"})
    context = {} if region is None else {"s3:LocationConstraint": region}
    assert not allowed(policy, "s3:CreateBucket", BUCKET, **context)


@pytest.mark.parametrize("action", sorted(BUCKET_ACTIONS))
def test_bucket_configuration_is_scoped_to_new_bucket(action):
    policy = load_policy()
    assert allowed(policy, action, BUCKET)
    assert not allowed(policy, action, "arn:aws:s3:::starchat-media")
    assert not allowed(policy, action, "arn:aws:s3:::starchat-media-218022113852-sg")
    assert not allowed(policy, action, "arn:aws:s3:::unrelated-bucket")


@pytest.mark.parametrize("prefix", ["downloads/", "downloads/ChatFlow", "downloads/versions/"])
def test_list_bucket_requires_downloads_prefix(prefix):
    policy = load_policy()
    assert allowed(policy, "s3:ListBucket", BUCKET, **{"s3:prefix": prefix})


@pytest.mark.parametrize("prefix", [None, "", "downloads", "media/", "business/", "synapse/", "downloads-other/"])
def test_list_bucket_rejects_unscoped_or_other_prefix(prefix):
    policy = load_policy()
    context = {} if prefix is None else {"s3:prefix": prefix}
    assert not allowed(policy, "s3:ListBucket", BUCKET, **context)


@pytest.mark.parametrize("action", ["s3:PutObject", "s3:GetObject"])
def test_object_access_is_only_downloads(action):
    policy = load_policy()
    assert allowed(policy, action, OBJECT)
    for resource in [BUCKET + "/business/file", BUCKET + "/synapse/file",
                     BUCKET + "/media/file", BUCKET + "/downloads-other/file",
                     "arn:aws:s3:::starchat-media/downloads/file"]:
        assert not allowed(policy, action, resource)


@pytest.mark.parametrize("action,resource", [
    ("s3:DeleteObject", OBJECT),
    ("s3:DeleteObjectVersion", OBJECT),
    ("s3:DeleteBucket", BUCKET),
    ("s3:ListAllMyBuckets", "*"),
    ("s3:PutObjectAcl", OBJECT),
    ("s3:PutBucketAcl", BUCKET),
    ("s3:PutBucketOwnershipControls", BUCKET),
    ("s3:PutAccountPublicAccessBlock", "*"),
    ("iam:PutRolePolicy", "*"),
    ("iam:PassRole", "*"),
    ("route53:ChangeResourceRecordSets", "*"),
    ("cloudfront:DeleteDistribution", DISTRIBUTION),
    ("cloudfront:DeleteOriginAccessControl", "*"),
    ("cloudfront:UpdateOriginAccessControl", "*"),
    ("cloudfront:UntagResource", DISTRIBUTION),
    ("cloudfront:CreateInvalidation", DISTRIBUTION),
    ("cloudfront:CreateDistribution", "*"),
    ("cloudfront:TagResource", DISTRIBUTION),
])
def test_no_deletion_iam_dns_acl_or_unneeded_writes(action, resource):
    policy = load_policy()
    assert not allowed(policy, action, resource,
                       **{"aws:RequestTag/Project": PROJECT,
                          "aws:ResourceTag/Project": PROJECT,
                          "aws:TagKeys": ["Project"]})


def test_required_cloudfront_wildcards_are_separate_and_minimal():
    policy = load_policy()
    oac, = statements_for(policy, "cloudfront:CreateOriginAccessControl")
    assert values(oac["Action"]) == ["cloudfront:CreateOriginAccessControl"]
    assert oac["Resource"] == "*"
    assert "Condition" not in oac  # OAC creation does not support tags or ARN scope.
    wildcard_actions = {action for statement in policy["Statement"]
                        if statement["Resource"] == "*"
                        for action in values(statement["Action"])}
    assert wildcard_actions == {
        "cloudfront:CreateOriginAccessControl",
        "cloudfront:ListDistributions", "cloudfront:ListOriginAccessControls"
    }


@pytest.mark.parametrize("action", ["cloudfront:GetDistribution", "cloudfront:GetDistributionConfig",
                                    "cloudfront:UpdateDistribution", "cloudfront:ListTagsForResource"])
def test_existing_distributions_require_account_and_existing_project_tag(action):
    policy = load_policy()
    assert allowed(policy, action, DISTRIBUTION, **{"aws:ResourceTag/Project": PROJECT})
    for context in [{}, {"aws:ResourceTag/Project": "Media"}, {"aws:RequestTag/Project": PROJECT}]:
        assert not allowed(policy, action, DISTRIBUTION, **context)
    assert not allowed(policy, action, "arn:aws:cloudfront::111111111111:distribution/EXAMPLE",
                       **{"aws:ResourceTag/Project": PROJECT})


@pytest.mark.parametrize("action", ["cloudfront:GetOriginAccessControl", "cloudfront:GetOriginAccessControlConfig"])
def test_oac_read_is_account_scoped_without_unsupported_tag_condition(action):
    policy = load_policy()
    statement, = statements_for(policy, action)
    assert statement["Resource"] == "arn:aws:cloudfront::218022113852:origin-access-control/*"
    assert "Condition" not in statement

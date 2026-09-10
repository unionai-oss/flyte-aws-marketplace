#!/usr/bin/env bash
# One-time setup in the AWS Marketplace SELLER account (747712783559).
#
# Everything here is idempotent-ish but creates IAM principals, so read it
# before running. Steps already applied are noted.
#
#   done  OIDC provider for GitHub Actions
#   done  AWSMarketplaceAmiIngestion role (lets Marketplace copy + scan AMIs)
#   done  s3://flyte-marketplace-assets-747712783559 (+ public read on devbox/*)
#   done  mp.flytedemo.app hosted zone, delegated by NS from the flytedemo.app
#         zone in 371290552455 — gives CI smoke stacks a namespace of their own
#         so they never deploy into a personal domain
#   this  github-actions-flyte-marketplace + github-actions-flyte-devbox-smoke
#
# Usage: AWS_PROFILE=union-seller infra/seller-account-setup.sh
set -euo pipefail
ACCOUNT=747712783559
REPO=unionai-oss/flyte-aws-marketplace
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

cat > "${WORK}/trust.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": [
        "repo:${REPO}:ref:refs/heads/main",
        "repo:${REPO}:environment:*"
      ]}
    }
  }]
}
EOF

# Scoped to what the two workflows actually do. Notably NOT enough to run the
# devbox smoke test, which deploys a full stack (CloudFormation, RDS, ELB,
# Cognito, IAM) — that needs a separate, broader role. See the note below.
cat > "${WORK}/perms.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DevboxAmiPointers",
      "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter"],
      "Resource": "arn:aws:ssm:*:${ACCOUNT}:parameter/flyte-devbox/*"
    },
    { "Sid": "EcrAuth", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*" },
    {
      "Sid": "MarketplaceEcrPush",
      "Effect": "Allow",
      "Action": ["ecr:BatchCheckLayerAvailability", "ecr:CompleteLayerUpload", "ecr:InitiateLayerUpload",
                 "ecr:PutImage", "ecr:UploadLayerPart", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
                 "ecr:DescribeImages", "ecr:ListImages"],
      "Resource": "arn:aws:ecr:*:709825985650:repository/union-ai/*"
    },
    {
      "Sid": "MarketplaceCatalog",
      "Effect": "Allow",
      "Action": ["aws-marketplace:StartChangeSet", "aws-marketplace:DescribeChangeSet",
                 "aws-marketplace:ListChangeSets", "aws-marketplace:DescribeEntity",
                 "aws-marketplace:ListEntities"],
      "Resource": "*"
    },
    {
      "Sid": "MarketplaceAssetBucket",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject"],
      "Resource": "arn:aws:s3:::flyte-marketplace-assets-${ACCOUNT}/*"
    }
  ]
}
EOF

# Trust for the smoke role: the devbox-smoke ENVIRONMENT only, never a branch.
# The environment is what carries the required-reviewer gate, so scoping the
# trust to it means an unreviewed run cannot assume a role this broad.
cat > "${WORK}/trust-smoke.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:${REPO}:environment:devbox-smoke"
      }
    }
  }]
}
EOF

# Idempotent: re-running must be a no-op, not a CreateRole collision. The trust
# policy is refreshed either way, so a changed REPO or ACCOUNT actually lands.
ensure_role() {
  local name="$1" trust="$2" desc="$3"
  if aws iam get-role --role-name "${name}" >/dev/null 2>&1; then
    echo ">> ${name} exists — refreshing trust policy"
    aws iam update-assume-role-policy --role-name "${name}" --policy-document "file://${trust}"
  else
    echo ">> creating ${name}"
    aws iam create-role --role-name "${name}" --description "${desc}" \
      --assume-role-policy-document "file://${trust}" --query 'Role.Arn' --output text
  fi
}

# ---- 1. publishing role: AMI builds + add-on publishing --------------------
ensure_role github-actions-flyte-marketplace "${WORK}/trust.json" \
  "GitHub Actions OIDC: devbox AMI builds + EKS add-on publishing"

# Packer needs to run an instance, snapshot it, and register an AMI. EC2 full
# access is the usual grant; scope it down with a permissions boundary if your
# account requires one.
aws iam attach-role-policy --role-name github-actions-flyte-marketplace \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

aws iam put-role-policy --role-name github-actions-flyte-marketplace \
  --policy-name flyte-marketplace-publish \
  --policy-document "file://${WORK}/perms.json"

# ---- 2. smoke-test role: deploys a whole throwaway devbox stack ------------
# Deliberately broad. The smoke test stands up CloudFormation, EC2, Aurora, an
# ALB, Cognito and the stack's own IAM roles and then tears it all down;
# enumerating that surface as a least-privilege policy is a losing game that
# breaks on every template change. The controls that matter are elsewhere: the
# trust policy admits only the devbox-smoke environment, and that environment
# carries required reviewers. Keep it that way — without the reviewer gate this
# is a near-admin credential reachable from a workflow file.
ensure_role github-actions-flyte-devbox-smoke "${WORK}/trust-smoke.json" \
  "GitHub Actions OIDC: devbox smoke test (full stack deploy + teardown)"

aws iam attach-role-policy --role-name github-actions-flyte-devbox-smoke \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess
aws iam attach-role-policy --role-name github-actions-flyte-devbox-smoke \
  --policy-arn arn:aws:iam::aws:policy/IAMFullAccess

echo
echo "Now set the repo variables so the workflows can find the roles:"
echo "  gh variable set AWS_PUBLISH_ROLE_ARN --repo ${REPO} \\"
echo "    --body arn:aws:iam::${ACCOUNT}:role/github-actions-flyte-marketplace"
echo "  gh variable set AWS_SMOKE_ROLE_ARN --repo ${REPO} \\"
echo "    --body arn:aws:iam::${ACCOUNT}:role/github-actions-flyte-devbox-smoke"
echo
echo "And put REQUIRED REVIEWERS on the devbox-smoke environment before the"
echo "first run — see the comment above the smoke role."

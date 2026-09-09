#!/usr/bin/env bash
# One-time setup in the AWS Marketplace SELLER account (747712783559).
#
# Everything here is idempotent-ish but creates IAM principals, so read it
# before running. Steps already applied are noted.
#
#   done  OIDC provider for GitHub Actions
#   done  AWSMarketplaceAmiIngestion role (lets Marketplace copy + scan AMIs)
#   done  s3://flyte-marketplace-assets-747712783559 (+ public read on devbox/*)
#   TODO  github-actions-flyte-marketplace role  <- this script
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

aws iam create-role --role-name github-actions-flyte-marketplace \
  --description "GitHub Actions OIDC: devbox AMI builds + EKS add-on publishing" \
  --assume-role-policy-document "file://${WORK}/trust.json" \
  --query 'Role.Arn' --output text

# Packer needs to run an instance, snapshot it, and register an AMI. EC2 full
# access is the usual grant; scope it down with a permissions boundary if your
# account requires one.
aws iam attach-role-policy --role-name github-actions-flyte-marketplace \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

aws iam put-role-policy --role-name github-actions-flyte-marketplace \
  --policy-name flyte-marketplace-publish \
  --policy-document "file://${WORK}/perms.json"

echo
echo "Now set the repo variable so the workflows can find it:"
echo "  gh variable set AWS_PUBLISH_ROLE_ARN --repo ${REPO} \\"
echo "    --body arn:aws:iam::${ACCOUNT}:role/github-actions-flyte-marketplace"

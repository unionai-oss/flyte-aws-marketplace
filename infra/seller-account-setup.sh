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
#
# ValidateListingTemplates is for package-marketplace.sh, which validates the
# root and nested templates before uploading them so a broken template is caught
# here rather than by a Marketplace reviewer. cloudformation:ValidateTemplate
# takes no resource-level conditions, hence Resource "*". (ec2:DescribeImages,
# which submit-version.sh uses to check AMI ownership, already comes from the
# AmazonEC2FullAccess attached below for packer.)
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
      "Sid": "ValidateListingTemplates",
      "Effect": "Allow",
      "Action": "cloudformation:ValidateTemplate",
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

# Submitting outlives a default session too. Marketplace validation alone ran
# 27 minutes on one version, and the submit job waits for it and then for the
# apply. A role cannot be assumed for longer than its MaxSessionDuration, so
# role-duration-seconds in the workflow is not enough on its own.
aws iam update-role --role-name github-actions-flyte-marketplace \
  --max-session-duration 14400

aws iam put-role-policy --role-name github-actions-flyte-marketplace \
  --policy-name flyte-marketplace-publish \
  --policy-document "file://${WORK}/perms.json"

# ---- 2. smoke-test role: deploys a whole throwaway devbox stack ------------
# Deliberately broad. The smoke test stands up CloudFormation, EC2, Aurora, an
# ALB, Cognito and the stack's own IAM roles and then tears it all down;
# enumerating every resource type as an allow-list is a losing game that breaks
# on every template change, so the breadth stays: PowerUserAccess covers the
# stack's EC2/RDS/ELB/Cognito/Route53 surface.
#
# What does NOT stay is IAMFullAccess. It was the reason this role needed a human
# gate - it can mint an admin role and hand it to an instance - and it was far
# wider than the job requires. CloudFormation auto-names the stack's roles from
# the stack name, so every IAM object the smoke test touches is
# flyte-devbox-smoke-*, and the IAM grant is scoped to exactly that.
#
# A deny-list then protects the things whose loss would actually hurt, none of
# which the smoke test has any business touching: the Marketplace asset bucket,
# the published AMI pointers, the Catalog API, the CI identities themselves, and
# any region other than the one it deploys into.
ensure_role github-actions-flyte-devbox-smoke "${WORK}/trust-smoke.json" \
  "GitHub Actions OIDC: devbox smoke test (full stack deploy + teardown)"

# The smoke job outlives a default session. Deploying the stack is ~14 minutes,
# and the pre-clean waits for any previous stack to finish deleting first - which
# it must, or the CREATE collides on retained names. One run took 60.5 minutes
# and its credentials expired mid-wait:
#
#   Waiter StackCreateComplete failed: (ExpiredToken) The security token
#   included in the request is expired
#
# A role cannot be assumed for longer than its MaxSessionDuration, so raising
# role-duration-seconds in the workflow is not enough on its own.
aws iam update-role --role-name github-actions-flyte-devbox-smoke \
  --max-session-duration 14400

aws iam attach-role-policy --role-name github-actions-flyte-devbox-smoke \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

# Idempotent downgrade: earlier revisions of this script attached IAMFullAccess.
if aws iam list-attached-role-policies --role-name github-actions-flyte-devbox-smoke \
     --query 'AttachedPolicies[?PolicyName==`IAMFullAccess`]' --output text | grep -q IAMFullAccess; then
  echo ">> detaching IAMFullAccess from the smoke role (replaced by a scoped grant)"
  aws iam detach-role-policy --role-name github-actions-flyte-devbox-smoke \
    --policy-arn arn:aws:iam::aws:policy/IAMFullAccess
fi

cat > "${WORK}/smoke-iam.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StackOwnedIamOnly",
      "Effect": "Allow",
      "Action": ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
                 "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy",
                 "iam:DeleteRolePolicy", "iam:GetRolePolicy", "iam:ListRolePolicies",
                 "iam:ListAttachedRolePolicies", "iam:UpdateAssumeRolePolicy", "iam:PassRole",
                 "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
                 "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
                 "iam:TagInstanceProfile"],
      "Resource": [
        "arn:aws:iam::${ACCOUNT}:role/flyte-devbox-smoke-*",
        "arn:aws:iam::${ACCOUNT}:instance-profile/flyte-devbox-smoke-*"
      ]
    },
    {
      "Sid": "ServiceLinkedRolesForTheStack",
      "Effect": "Allow",
      "Action": ["iam:CreateServiceLinkedRole", "iam:ListRoles", "iam:ListInstanceProfiles"],
      "Resource": "*"
    },
    {
      "Sid": "NoPrivilegedPolicyAttachment",
      "Effect": "Deny",
      "Action": ["iam:AttachRolePolicy", "iam:AttachUserPolicy", "iam:AttachGroupPolicy"],
      "Resource": "*",
      "Condition": {"ArnLike": {"iam:PolicyARN": [
        "arn:aws:iam::aws:policy/AdministratorAccess",
        "arn:aws:iam::aws:policy/IAMFullAccess",
        "arn:aws:iam::aws:policy/PowerUserAccess"
      ]}}
    },
    {
      "Sid": "KeepAwayFromTheCiIdentities",
      "Effect": "Deny",
      "Action": ["iam:*"],
      "Resource": [
        "arn:aws:iam::${ACCOUNT}:role/github-actions-flyte-marketplace",
        "arn:aws:iam::${ACCOUNT}:role/github-actions-flyte-devbox-smoke",
        "arn:aws:iam::${ACCOUNT}:role/AWSMarketplaceAmiIngestion",
        "arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
      ]
    },
    {
      "Sid": "KeepAwayFromMarketplaceArtifacts",
      "Effect": "Deny",
      "Action": ["s3:DeleteBucket", "s3:DeleteObject", "s3:DeleteObjectVersion",
                 "s3:PutBucketPolicy", "s3:PutObject"],
      "Resource": ["arn:aws:s3:::flyte-marketplace-assets-${ACCOUNT}",
                   "arn:aws:s3:::flyte-marketplace-assets-${ACCOUNT}/*"]
    },
    {
      "Sid": "KeepAwayFromThePublishedAmiPointers",
      "Effect": "Deny",
      "Action": ["ssm:PutParameter", "ssm:DeleteParameter", "ssm:DeleteParameters"],
      "Resource": "arn:aws:ssm:*:${ACCOUNT}:parameter/flyte-devbox/*"
    },
    {
      "Sid": "NoTouchingItsOwnCostAlarm",
      "Effect": "Deny",
      "Action": ["budgets:*", "ce:*"],
      "Resource": "*"
    },
    {
      "Sid": "NoMarketplacePublishing",
      "Effect": "Deny",
      "Action": ["aws-marketplace:*"],
      "Resource": "*"
    },
    {
      "Sid": "OneRegionOnly",
      "Effect": "Deny",
      "NotAction": ["iam:*", "sts:*", "cloudfront:*", "route53:*", "s3:*", "support:*"],
      "Resource": "*",
      "Condition": {"StringNotEquals": {"aws:RequestedRegion": "us-east-1"}}
    }
  ]
}
EOF

aws iam put-role-policy --role-name github-actions-flyte-devbox-smoke \
  --policy-name flyte-devbox-smoke-guardrails \
  --policy-document "file://${WORK}/smoke-iam.json"

# ---- 3. cost alarms -------------------------------------------------------
# The smoke test deploys Aurora + an ALB + an EC2 for ~30 minutes per run, and
# nothing in the pipeline caps that. With the reviewer gate off, a loop or a bad
# merge can run it repeatedly, so the budget is the backstop that used to be a
# human looking at the approval prompt.
#
# One MONTHLY COST budget of $100 with alerts at 50% ($50) and 100% ($100), plus
# a forecast alert so it warns on the way there rather than after the fact.
#
# Alerts go to the team alias, not an individual, so they survive someone being
# on holiday. Override for a personal account with BUDGET_EMAIL=..., or set it
# empty (BUDGET_EMAIL=) to skip the alarms entirely.
BUDGET_EMAIL="${BUDGET_EMAIL-sales@union.ai}"
BUDGET_NAME="flyte-marketplace-monthly"
if [ -z "${BUDGET_EMAIL}" ]; then
  echo
  echo ">> BUDGET_EMAIL is empty — skipping the cost alarms."
else
  cat > "${WORK}/budget.json" <<EOF
{
  "BudgetName": "${BUDGET_NAME}",
  "BudgetLimit": {"Amount": "100", "Unit": "USD"},
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
EOF
  cat > "${WORK}/budget-notifications.json" <<EOF
[
  {"Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN",
                    "Threshold": 50, "ThresholdType": "PERCENTAGE"},
   "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "${BUDGET_EMAIL}"}]},
  {"Notification": {"NotificationType": "ACTUAL", "ComparisonOperator": "GREATER_THAN",
                    "Threshold": 100, "ThresholdType": "PERCENTAGE"},
   "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "${BUDGET_EMAIL}"}]},
  {"Notification": {"NotificationType": "FORECASTED", "ComparisonOperator": "GREATER_THAN",
                    "Threshold": 100, "ThresholdType": "PERCENTAGE"},
   "Subscribers": [{"SubscriptionType": "EMAIL", "Address": "${BUDGET_EMAIL}"}]}
]
EOF
  # Idempotent by replacement: the API has no way to reconcile a budget's
  # notification set in place, and a budget is pure alarm config with no history
  # worth preserving, so re-running rebuilds it.
  if aws budgets describe-budget --account-id "${ACCOUNT}" \
       --budget-name "${BUDGET_NAME}" >/dev/null 2>&1; then
    echo ">> ${BUDGET_NAME} exists — recreating it so the thresholds match this script"
    aws budgets delete-budget --account-id "${ACCOUNT}" --budget-name "${BUDGET_NAME}"
  fi
  aws budgets create-budget --account-id "${ACCOUNT}" \
    --budget "file://${WORK}/budget.json" \
    --notifications-with-subscribers "file://${WORK}/budget-notifications.json"
  echo ">> cost alarms: \$50 and \$100 actual, \$100 forecast -> ${BUDGET_EMAIL}"
  echo "   AWS emails a confirmation for a new address; accept it or the alerts never arrive."
fi

echo
echo "Now set the repo variables so the workflows can find the roles:"
echo "  gh variable set AWS_PUBLISH_ROLE_ARN --repo ${REPO} \\"
echo "    --body arn:aws:iam::${ACCOUNT}:role/github-actions-flyte-marketplace"
echo "  gh variable set AWS_SMOKE_ROLE_ARN --repo ${REPO} \\"
echo "    --body arn:aws:iam::${ACCOUNT}:role/github-actions-flyte-devbox-smoke"
echo
echo
echo "Reviewers on devbox-smoke / marketplace-publish are now optional — see"
echo ".github/workflows/README.md, 'Unattended runs'. Re-run THIS script before"
echo "removing them: it is what downgrades the smoke role."

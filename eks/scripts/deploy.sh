#!/usr/bin/env bash
# Package the nested templates to S3 and deploy the full-stack CloudFormation
# product. This is what the Marketplace launch does under the hood; it is also
# how you deploy for live validation before publishing.
#
# Usage:
#   STAGING_BUCKET=my-cfn-staging AWS_REGION=us-east-1 scripts/deploy.sh <stack-name> \
#     [ParamKey=ParamValue ...]
#
# Dev mode:  scripts/deploy.sh flyte-dev
# Prod mode: scripts/deploy.sh flyte-prod \
#              DomainName=example.com HostedZoneId=Z123 CognitoDomainPrefix=my-flyte
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${STAGING_BUCKET:?set STAGING_BUCKET to an S3 bucket for nested templates}"
: "${AWS_REGION:?set AWS_REGION}"
STACK="${1:?usage: deploy.sh <stack-name> [Key=Value ...]}"; shift || true

PACKAGED="$(mktemp -t packaged-XXXX.yaml)"

echo ">> packaging nested templates -> s3://${STAGING_BUCKET}"
aws cloudformation package \
  --region "${AWS_REGION}" \
  --template-file "${REPO_ROOT}/cloudformation/root.yaml" \
  --s3-bucket "${STAGING_BUCKET}" \
  --s3-prefix "flyte-eks/$(basename "${STACK}")" \
  --output-template-file "${PACKAGED}"

echo ">> deploying stack ${STACK}"
# Build one args array and expand it once — avoids the bash 3.2 (macOS) quirk
# where expanding a possibly-empty array under `set -u` is an "unbound variable".
DEPLOY_ARGS=(cloudformation deploy
  --region "${AWS_REGION}"
  --stack-name "${STACK}"
  --template-file "${PACKAGED}"
  --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND)
# DISABLE_ROLLBACK=1 leaves a failed stack (and its live cluster) standing for
# debugging instead of tearing everything down. Use during development only.
if [[ "${DISABLE_ROLLBACK:-0}" == "1" ]]; then DEPLOY_ARGS+=(--disable-rollback); fi
if [[ "$#" -gt 0 ]]; then DEPLOY_ARGS+=(--parameter-overrides "$@"); fi
aws "${DEPLOY_ARGS[@]}"

echo ">> outputs:"
aws cloudformation describe-stacks --region "${AWS_REGION}" --stack-name "${STACK}" \
  --query "Stacks[0].Outputs" --output table

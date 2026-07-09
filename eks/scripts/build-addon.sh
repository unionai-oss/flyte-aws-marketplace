#!/usr/bin/env bash
# Build & publish the Flyte EKS add-on artifact to the AWS Marketplace-provided
# ECR (Artifact A). This is the "build the add-on" half of the pipeline; the
# resolver's helm fallback covers the "run it before it's published" half.
#
# Steps (Marketplace container add-on flow):
#   1. vendor the pinned chart
#   2. relocate all chart images into the Marketplace ECR namespace
#   3. package the wrapper chart as an OCI artifact + push to Marketplace ECR
#   4. (in the Marketplace portal / API) attach configuration schema and submit
#      the version for Conformitron validation
#
# Requires: helm, aws, and the Marketplace ECR registry from the listing.
# Env:
#   MARKETPLACE_ECR   e.g. 709825985650.dkr.ecr.us-east-1.amazonaws.com/<listing>
#   AWS_REGION
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"
: "${MARKETPLACE_ECR:?MARKETPLACE_ECR is required (from the Marketplace listing)}"
: "${AWS_REGION:?AWS_REGION is required}"
CHART_DIR="${REPO_ROOT}/addon/chart/flyte-eks"

echo ">> [1/4] vendor chart"
"${REPO_ROOT}/scripts/vendor-chart.sh"

echo ">> [2/4] enumerate chart images (relocation targets)"
# helm template + parse images. In CI these are mirrored into MARKETPLACE_ECR
# with `docker pull/tag/push` (or crane/skopeo). Left as an explicit list so the
# metadata.yaml images[] stays authoritative and reviewable.
helm template flyte "${CHART_DIR}" -f "${REPO_ROOT}/addon/values/example-config.yaml" \
  | grep -Eo 'image: "?[^"]+' | sed 's/image: //; s/"//g' | sort -u \
  | tee "${REPO_ROOT}/build-images.txt"
echo ">> TODO(pipeline): mirror the images above into ${MARKETPLACE_ECR}"

echo ">> [3/4] package + push wrapper chart as OCI artifact"
mkdir -p "${REPO_ROOT}/dist"
helm package "${CHART_DIR}" --destination "${REPO_ROOT}/dist"
aws ecr get-login-password --region "${AWS_REGION}" \
  | helm registry login --username AWS --password-stdin "${MARKETPLACE_ECR%%/*}"
helm push "${REPO_ROOT}/dist/flyte-eks-${ADDON_VERSION#v}.tgz" "oci://${MARKETPLACE_ECR}"

echo ">> [4/4] Submit version ${ADDON_VERSION} in the Marketplace portal:"
echo "         - attach addon/addon-configuration-schema.json"
echo "         - run Conformitron / Addons Transformer validation"
echo "         See MARKETPLACE.md."

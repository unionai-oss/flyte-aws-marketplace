#!/usr/bin/env bash
# Build & publish the Flyte EKS add-on artifact to the AWS Marketplace-provided
# ECR (Artifact A). This is the "build the add-on" half of the pipeline; the
# resolver's helm fallback covers the "run it before it's published" half.
#
# Steps (Marketplace container add-on flow):
#   1. vendor the pinned chart
#   2. relocate every image the chart renders into the Marketplace ECR
#   3. package the wrapper chart as an OCI artifact + push to Marketplace ECR
#   4. (in the Marketplace portal) add the version, attaching the chart URI and
#      the full image list, for the EKS console add-on delivery option
#
# Requires: helm >= 3.19, aws, and crane (github.com/google/go-containerregistry)
#   brew install crane   |   go install github.com/google/go-containerregistry/cmd/crane@latest
#
# Why crane and not `docker pull/tag/push`: the source images are multi-arch and
# Marketplace requires the add-on to support both AMD64 and ARM64, which a
# docker pull/push round-trip flattens to the local machine's architecture.
# `docker buildx imagetools create` preserves the index but does not copy blobs
# across registries. crane does both.
#
# Env:
#   AWS_REGION        region of the Marketplace ECR (us-east-1)
#   MARKETPLACE_ECR   override the registry/repo from versions.env (optional)
#   SKIP_IMAGES=1     push only the chart (images already mirrored)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"
: "${AWS_REGION:?AWS_REGION is required}"
CHART_DIR="${REPO_ROOT}/addon/chart/flyte-eks-add-on"
MARKETPLACE_ECR="${MARKETPLACE_ECR:?MARKETPLACE_ECR is required (set in versions.env)}"
REGISTRY="${MARKETPLACE_ECR%%/*}"
# helm push appends <chart name>:<version> to the OCI ref, and the chart is named
# flyte-eks-add-on to match the Marketplace-provisioned repository. So the push
# target is the repo's PARENT (the seller namespace), not the repo itself.
CHART_PUSH_TARGET="oci://${MARKETPLACE_ECR%/*}"

need() { command -v "$1" >/dev/null || { echo "$1 not found on PATH — see the header of this script" >&2; exit 1; }; }
need helm; need aws; need crane

# Marketplace validates submitted charts with helm 3.19; lint/template behaviour
# differs enough between minors that building with an older helm can ship a
# chart that fails ingestion.
HELM_V="$(helm version --template '{{.Version}}' | tr -d 'v')"
if [[ "$(printf '%s\n%s\n' "${HELM_MIN_VERSION}" "${HELM_V}" | sort -V | head -1)" != "${HELM_MIN_VERSION}" ]]; then
  echo "helm ${HELM_V} is older than the Marketplace validation floor ${HELM_MIN_VERSION}" >&2
  exit 1
fi

echo ">> [1/4] vendor chart"
"${REPO_ROOT}/scripts/vendor-chart.sh"

echo ">> [2/4] authenticate to ${REGISTRY}"
aws ecr get-login-password --region "${AWS_REGION}" \
  | crane auth login --username AWS --password-stdin "${REGISTRY}"
aws ecr get-login-password --region "${AWS_REGION}" \
  | helm registry login --username AWS --password-stdin "${REGISTRY}"

echo ">> [3/4] relocate images into ${MARKETPLACE_ECR}"
if [[ "${SKIP_IMAGES:-0}" == "1" ]]; then
  echo "   SKIP_IMAGES=1 — skipping"
else
  for row in "${MP_IMAGES[@]}"; do
    src="${row%%|*}"
    dst="${MARKETPLACE_ECR}:${row##*|}"
    echo "   ${src}"
    echo "     -> ${dst}"
    # Copy the whole index (all platforms, all referrers), then rewrite the
    # index in place keeping only the two required platforms. That second pass
    # drops the in-toto attestation manifests that every buildx-built image
    # carries as `unknown/unknown` children — Marketplace's security scan
    # rejects them as "layers with unsupported architectures".
    crane copy "${src}" "${dst}"
    crane index filter "${dst}" \
      --platform linux/amd64 --platform linux/arm64 \
      -t "${dst}"

    # Fail loudly rather than discovering this during Marketplace ingestion.
    platforms="$(crane manifest "${dst}" \
      | jq -r '[.manifests[]?.platform | "\(.os)/\(.architecture)"] | sort | join(",")')"
    [[ "${platforms}" == "linux/amd64,linux/arm64" ]] \
      || { echo "     FAIL: ${dst} has platforms [${platforms}], expected [${MP_PLATFORMS}]" >&2; exit 1; }
    echo "     ok: ${platforms}"
  done
fi

echo ">> [4/4] package + push wrapper chart as OCI artifact"
mkdir -p "${REPO_ROOT}/dist"
rm -f "${REPO_ROOT}/dist/flyte-eks-add-on-"*.tgz
helm package "${CHART_DIR}" --destination "${REPO_ROOT}/dist"
helm push "${REPO_ROOT}/dist/flyte-eks-add-on-${ADDON_VERSION#v}.tgz" "${CHART_PUSH_TARGET}"

cat <<EOF

>> Pushed. Now add the version in the Marketplace portal
   (Server products -> this product -> Request changes -> Add new version),
   choosing the "Amazon EKS console add-on" delivery option:

     Helm chart URI  : ${MARKETPLACE_ECR}:${ADDON_VERSION#v}
     Container images: $(for row in "${MP_IMAGES[@]}"; do printf '\n                       %s:%s' "${MARKETPLACE_ECR}" "${row##*|}"; done)
     Add-on version  : ${ADDON_VERSION#v}      (major.minor.patch — no leading v)
     Namespace       : ${ADDON_NAMESPACE}
     Architectures   : ${MP_PLATFORMS}
     Visibility      : Limited

   Every image above must be listed, or ingestion fails with
   INVALID_HELM_UNDECLARED_IMAGES. See MARKETPLACE.md.
EOF

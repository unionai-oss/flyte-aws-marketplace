#!/usr/bin/env bash
# Dual-mode Flyte installer / resolver.
#
# Picks the install path automatically:
#   * If the pinned ADDON_VERSION is live in the EKS add-on catalog for this
#     account+region  -> installs via `aws eks create-addon` (Artifact A path).
#   * Otherwise (unpublished / pre-review dev) -> installs the SAME vendored
#     wrapper chart via `helm upgrade --install` (fallback path).
#
# Both paths consume the identical rendered config document, so software +
# config are equivalent regardless of which path runs. This is what lets you
# validate unpublished changes immediately, before the Marketplace listing goes
# live, while keeping the add-on as the eventual production mechanism.
#
# Usage:
#   CLUSTER_NAME=my-eks AWS_REGION=us-east-1 CONFIG_FILE=/path/config.yaml \
#     scripts/resolve-install.sh
#
# Env:
#   CLUSTER_NAME   (required) target EKS cluster
#   AWS_REGION     (required) region
#   CONFIG_FILE    (required) rendered config from render-config.sh
#   INSTALL_MODE   auto | addon | helm   (default: auto)
#   POD_IDENTITY_ROLE_ARN  if set, wired to the flyte-backend SA on both paths
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"

: "${CLUSTER_NAME:?CLUSTER_NAME is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${CONFIG_FILE:?CONFIG_FILE is required (see scripts/render-config.sh)}"
INSTALL_MODE="${INSTALL_MODE:-auto}"

SA_NAME="flyte-backend"   # must match wrapper values.yaml + PodIdentityAssociation

# Resolve the CONCRETE catalog version string for the pinned ADDON_VERSION, or
# print nothing if it is not published for this Kubernetes version.
#
# AWS appends its own build suffix when it ingests a seller's add-on: v0.1.2
# ships as "v0.1.2-eksbuild.1". This used to compare for exact equality against
# ADDON_VERSION, which therefore never matched anything AWS had actually
# published - the resolver reported "not published" for a live add-on and fell
# through to helm every time, silently. Matching a live catalog entry is the
# whole trigger for the add-on path, so that bug meant the path could not fire
# at all.
#
# create-addon needs the full suffixed string too, so resolve it rather than
# assume it: the suffix is AWS's and can be -eksbuild.2 on a rebuild.
resolve_published_addon_version() {
  aws eks describe-addon-versions \
    --region "${AWS_REGION}" \
    --addon-name "${ADDON_PRODUCT_NAME}" \
    --kubernetes-version "${EKS_K8S_VERSION}" \
    --query "addons[].addonVersions[?addonVersion=='${ADDON_VERSION}' || starts_with(addonVersion, '${ADDON_VERSION}-eksbuild')].addonVersion | [] | sort(@) | [-1]" \
    --output text 2>/dev/null | grep -v '^None$' || true
}

install_via_addon() {
  # Falls back to the pinned string when called directly with INSTALL_MODE=addon,
  # so an explicit request still reaches AWS and fails with AWS's own error
  # rather than being quietly reinterpreted here.
  local version="${RESOLVED_ADDON_VERSION:-${ADDON_VERSION}}"
  echo ">> Installing Flyte via EKS add-on ${ADDON_PRODUCT_NAME} ${version}"
  local pod_id_args=()
  if [[ -n "${POD_IDENTITY_ROLE_ARN:-}" ]]; then
    pod_id_args=(--pod-identity-associations \
      "serviceAccount=${SA_NAME},roleArn=${POD_IDENTITY_ROLE_ARN}")
  fi
  aws eks create-addon \
    --region "${AWS_REGION}" \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name "${ADDON_PRODUCT_NAME}" \
    --addon-version "${version}" \
    --resolve-conflicts OVERWRITE \
    --configuration-values "file://${CONFIG_FILE}" \
    "${pod_id_args[@]}"

  echo ">> Waiting for add-on to become ACTIVE..."
  aws eks wait addon-active \
    --region "${AWS_REGION}" \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name "${ADDON_PRODUCT_NAME}"
}

install_via_helm() {
  echo ">> Installing Flyte via helm fallback (add-on ${ADDON_VERSION} not published)"
  local chart_dir="${REPO_ROOT}/addon/chart/flyte-eks-add-on"
  # vendor-chart.sh unpacks the dependency into charts/<name>/ so Chart.yaml can
  # reference it with file:// (Marketplace forbids external dependencies).
  if [[ ! -f "${chart_dir}/charts/${FLYTE_CHART_NAME}/Chart.yaml" ]]; then
    echo ">> Chart not vendored yet; running vendor-chart.sh"
    "${REPO_ROOT}/scripts/vendor-chart.sh"
  fi

  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}" >/dev/null

  # Pod Identity on the fallback path: create the association out-of-band so the
  # flyte-backend SA gets the same S3 role the add-on path would grant.
  if [[ -n "${POD_IDENTITY_ROLE_ARN:-}" ]]; then
    kubectl create namespace "${ADDON_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
    if ! aws eks list-pod-identity-associations --region "${AWS_REGION}" \
        --cluster-name "${CLUSTER_NAME}" --namespace "${ADDON_NAMESPACE}" \
        --query "associations[?serviceAccount=='${SA_NAME}']" --output text | grep -q .; then
      aws eks create-pod-identity-association \
        --region "${AWS_REGION}" --cluster-name "${CLUSTER_NAME}" \
        --namespace "${ADDON_NAMESPACE}" --service-account "${SA_NAME}" \
        --role-arn "${POD_IDENTITY_ROLE_ARN}"
    fi
  fi

  # No --dependency-update: the file:// dependency source lives inside charts/
  # itself, so re-resolving it would delete the tree it is copying from.
  helm upgrade --install flyte "${chart_dir}" \
    --namespace "${ADDON_NAMESPACE}" --create-namespace \
    -f "${CONFIG_FILE}" \
    --wait --timeout 15m
}

case "${INSTALL_MODE}" in
  addon) install_via_addon ;;
  helm)  install_via_helm ;;
  auto)
    RESOLVED_ADDON_VERSION="$(resolve_published_addon_version)"
    if [[ -n "${RESOLVED_ADDON_VERSION}" ]]; then
      echo ">> Resolver: ${ADDON_VERSION} is published as ${RESOLVED_ADDON_VERSION} -> add-on path"
      install_via_addon
    else
      echo ">> Resolver: ${ADDON_VERSION} is NOT in the ${ADDON_PRODUCT_NAME} catalog"
      echo "   for Kubernetes ${EKS_K8S_VERSION} in ${AWS_REGION} -> helm fallback."
      echo "   Published versions AWS does offer:"
      aws eks describe-addon-versions --region "${AWS_REGION}" \
        --addon-name "${ADDON_PRODUCT_NAME}" --kubernetes-version "${EKS_K8S_VERSION}" \
        --query 'addons[].addonVersions[].addonVersion' --output text 2>/dev/null \
        | tr '\t' '\n' | sed 's/^/     /' || echo "     (none)"
      install_via_helm
    fi
    ;;
  *) echo "Unknown INSTALL_MODE: ${INSTALL_MODE} (expected auto|addon|helm)" >&2; exit 2 ;;
esac

echo ">> Flyte install complete."

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

addon_version_is_published() {
  # Returns 0 if ADDON_VERSION for ADDON_PRODUCT_NAME is offered by the catalog
  # for the cluster's Kubernetes version in this region.
  aws eks describe-addon-versions \
    --region "${AWS_REGION}" \
    --addon-name "${ADDON_PRODUCT_NAME}" \
    --kubernetes-version "${EKS_K8S_VERSION}" \
    --query "addons[].addonVersions[?addonVersion=='${ADDON_VERSION}'] | [] | [0].addonVersion" \
    --output text 2>/dev/null | grep -qx "${ADDON_VERSION}"
}

install_via_addon() {
  echo ">> Installing Flyte via EKS add-on ${ADDON_PRODUCT_NAME} ${ADDON_VERSION}"
  local pod_id_args=()
  if [[ -n "${POD_IDENTITY_ROLE_ARN:-}" ]]; then
    pod_id_args=(--pod-identity-associations \
      "serviceAccount=${SA_NAME},roleArn=${POD_IDENTITY_ROLE_ARN}")
  fi
  aws eks create-addon \
    --region "${AWS_REGION}" \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name "${ADDON_PRODUCT_NAME}" \
    --addon-version "${ADDON_VERSION}" \
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
  local chart_dir="${REPO_ROOT}/addon/chart/flyte-eks"
  if [[ ! -d "${chart_dir}/charts" ]] || ! ls "${chart_dir}/charts/${FLYTE_CHART_NAME}"-*.tgz >/dev/null 2>&1; then
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

  helm upgrade --install flyte "${chart_dir}" \
    --namespace "${ADDON_NAMESPACE}" --create-namespace \
    --dependency-update \
    -f "${CONFIG_FILE}" \
    --wait --timeout 15m
}

case "${INSTALL_MODE}" in
  addon) install_via_addon ;;
  helm)  install_via_helm ;;
  auto)
    if addon_version_is_published; then
      echo ">> Resolver: add-on ${ADDON_VERSION} is published -> add-on path"
      install_via_addon
    else
      echo ">> Resolver: add-on ${ADDON_VERSION} NOT published -> helm fallback"
      install_via_helm
    fi
    ;;
  *) echo "Unknown INSTALL_MODE: ${INSTALL_MODE} (expected auto|addon|helm)" >&2; exit 2 ;;
esac

echo ">> Flyte install complete."

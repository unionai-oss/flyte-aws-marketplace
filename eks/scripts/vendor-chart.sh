#!/usr/bin/env bash
# Fetch the pinned upstream flyte-binary chart into the wrapper chart's charts/
# directory so the add-on package is fully self-contained (Marketplace add-ons
# must not fetch dependencies from the public internet at install time).
#
# The chart is vendored UNPACKED, as charts/flyte-binary/, because Chart.yaml
# references it with `repository: file://charts/flyte-binary`. Marketplace
# rejects dependencies sourced from anywhere outside the parent chart directory
# (INVALID_DEPENDENT_HELM_CHARTS), and a file:// reference has to resolve to a
# directory containing a Chart.yaml, not to a .tgz.
#
# Usage: scripts/vendor-chart.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"

WRAPPER_DIR="${REPO_ROOT}/addon/chart/flyte-eks-add-on"
CHARTS_DIR="${WRAPPER_DIR}/charts"

command -v helm >/dev/null || { echo "helm not found on PATH" >&2; exit 1; }

echo ">> Vendoring ${FLYTE_CHART_NAME} ${FLYTE_CHART_VERSION} from ${FLYTE_CHART_REPO}"
rm -rf "${CHARTS_DIR}"
mkdir -p "${CHARTS_DIR}"

# `helm pull --untar` writes charts/flyte-binary/ (the chart's own name), which
# is exactly the path Chart.yaml's file:// dependency points at.
helm pull "${FLYTE_CHART_NAME}" \
  --repo "${FLYTE_CHART_REPO}" \
  --version "${FLYTE_CHART_VERSION}" \
  --untar \
  --untardir "${CHARTS_DIR}"

[[ -f "${CHARTS_DIR}/${FLYTE_CHART_NAME}/Chart.yaml" ]] \
  || { echo "vendored chart missing Chart.yaml at ${CHARTS_DIR}/${FLYTE_CHART_NAME}" >&2; exit 1; }

echo ">> Vendored:"
ls -la "${CHARTS_DIR}/${FLYTE_CHART_NAME}"

# Keep Chart.yaml dependency pin in sync for auditability.
echo ">> Reminder: addon/chart/flyte-eks-add-on/Chart.yaml must pin ${FLYTE_CHART_NAME} ${FLYTE_CHART_VERSION}"
echo ">> Done. The wrapper chart is now self-contained."

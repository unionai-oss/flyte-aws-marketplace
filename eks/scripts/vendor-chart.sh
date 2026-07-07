#!/usr/bin/env bash
# Fetch the pinned upstream flyte-binary chart into the wrapper chart's charts/
# directory so the add-on package is fully self-contained (Marketplace add-ons
# must not fetch dependencies from the public internet at install time).
#
# Usage: scripts/vendor-chart.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"

WRAPPER_DIR="${REPO_ROOT}/addon/chart/flyte-eks"
CHARTS_DIR="${WRAPPER_DIR}/charts"

command -v helm >/dev/null || { echo "helm not found on PATH" >&2; exit 1; }

echo ">> Vendoring ${FLYTE_CHART_NAME} ${FLYTE_CHART_VERSION} from ${FLYTE_CHART_REPO}"
mkdir -p "${CHARTS_DIR}"
rm -f "${CHARTS_DIR}/${FLYTE_CHART_NAME}"-*.tgz

helm pull "${FLYTE_CHART_NAME}" \
  --repo "${FLYTE_CHART_REPO}" \
  --version "${FLYTE_CHART_VERSION}" \
  --destination "${CHARTS_DIR}"

echo ">> Vendored:"
ls -la "${CHARTS_DIR}"

# Keep Chart.yaml dependency pin in sync for auditability.
echo ">> Reminder: addon/chart/flyte-eks/Chart.yaml must pin ${FLYTE_CHART_NAME} ${FLYTE_CHART_VERSION}"
echo ">> Done. The wrapper chart is now self-contained."

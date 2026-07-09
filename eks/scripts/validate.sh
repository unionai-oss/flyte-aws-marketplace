#!/usr/bin/env bash
# Offline validation of the add-on package. Runs anywhere helm is installed; no
# AWS account or cluster required. CI runs this on every PR.
#
# Checks:
#   1. versions.env pins agree with Chart.yaml and metadata.yaml
#   2. the wrapper chart vendors and its dependencies resolve
#   3. `helm lint` passes
#   4. `helm template` renders cleanly with the example config merged in
#   5. the rendered manifests actually reflect the external S3/DB config
#      (guards against value-path drift when upgrading flyte-binary)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONO_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
source "${REPO_ROOT}/versions.env"
CHART_DIR="${REPO_ROOT}/addon/chart/flyte-eks"
CONFIG="${REPO_ROOT}/addon/values/example-config.yaml"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "== 0. cfn-lint (root + eks templates + shared common) =="
if command -v cfn-lint >/dev/null 2>&1; then
  cfn-lint --config-file "${MONO_ROOT}/.cfnlintrc" \
    "${REPO_ROOT}/cloudformation/root.yaml" \
    "${REPO_ROOT}/cloudformation/templates/"*.yaml \
    "${MONO_ROOT}/common/cloudformation/"*.yaml \
    || fail "cfn-lint reported errors"
  echo "ok"
else
  echo "SKIP: cfn-lint not installed (pip install cfn-lint)"
fi

echo "== 1. version pin consistency =="
grep -q "version: ${ADDON_VERSION#v}" "${CHART_DIR}/Chart.yaml" \
  || fail "Chart.yaml version != ADDON_VERSION (${ADDON_VERSION})"
grep -q "version: \"${ADDON_VERSION#v}\"" "${REPO_ROOT}/addon/metadata.yaml" \
  || fail "metadata.yaml version != ADDON_VERSION (${ADDON_VERSION})"
grep -q "version: ${FLYTE_CHART_VERSION}" "${CHART_DIR}/Chart.yaml" \
  || fail "Chart.yaml flyte-binary dep != FLYTE_CHART_VERSION (${FLYTE_CHART_VERSION})"
echo "ok"

echo "== 2. vendor chart =="
"${REPO_ROOT}/scripts/vendor-chart.sh"

echo "== 3. helm lint =="
helm lint "${CHART_DIR}" -f "${CONFIG}"

echo "== 4. helm template renders =="
RENDERED="$(helm template flyte "${CHART_DIR}" -f "${CONFIG}")"
echo "${RENDERED}" | head -1 >/dev/null

echo "== 5. rendered manifests reflect external config =="
# The generated Flyte backend config (003-storage.yaml / 002-database.yaml) must
# carry the S3 region + bucket and the Aurora host from the example config. If
# flyte-binary renamed/renested a value path in an upgrade, these assertions
# catch it before we ship. (v2 nests the live DB config under database.postgres;
# a regression to the flat path would leave the default 127.0.0.1 in place.)
echo "${RENDERED}" | grep -q "flyte-example-bucket" \
  || fail "S3 bucket not present in rendered config (storage value-path drift?)"
echo "${RENDERED}" | grep -q "cluster-abcdef.us-east-1.rds.amazonaws.com" \
  || fail "DB host not present in rendered config (database value-path drift?)"

# Extract the effective database config block and assert the Aurora host WON the
# merge over the chart's localhost default. This is the check that catches the
# v1-flat-vs-v2-postgres value-path trap.
DBBLOCK="$(echo "${RENDERED}" | awk '/002-database.yaml: \|/{f=1} f{print} /003-storage.yaml/{f=0}')"
echo "${DBBLOCK}" | grep -q "host: flyte.cluster-abcdef.us-east-1.rds.amazonaws.com" \
  || fail "Aurora host did not land in the effective postgres block (v1/v2 path drift)"
echo "${DBBLOCK}" | grep -q "host: 127.0.0.1" \
  && fail "database still points at 127.0.0.1 — configuration.database.postgres.host was not applied" || true

# S3 auth must be IAM (Pod Identity), never static keys.
echo "${RENDERED}" | grep -q "auth_type: iam" \
  || fail "S3 auth_type is not iam in rendered storage config"
echo "${RENDERED}" | grep -qiE "access_key|secret_key|accessKey|secretKey" \
  && fail "static S3 credentials appear in rendered config — must use Pod Identity (iam)" || true

# The DB password must never appear inline in rendered manifests.
echo "${RENDERED}" | grep -qiE "^\s*password: .+[A-Za-z0-9]" \
  && fail "an inline password appears in rendered manifests — must use passwordPath" || true

echo "ALL CHECKS PASSED"

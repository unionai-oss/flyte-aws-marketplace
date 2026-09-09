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
#   6. AWS Marketplace EKS add-on packaging rules — the ones that are checkable
#      offline, so ingestion failures surface here instead of in a review cycle
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MONO_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"
source "${REPO_ROOT}/versions.env"
CHART_DIR="${REPO_ROOT}/addon/chart/flyte-eks-add-on"
CONFIG="${REPO_ROOT}/addon/values/example-config.yaml"
METADATA="${REPO_ROOT}/addon/metadata.yaml"
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
grep -q "version: \"${ADDON_VERSION#v}\"" "${METADATA}" \
  || fail "metadata.yaml version != ADDON_VERSION (${ADDON_VERSION})"
grep -q "version: ${FLYTE_CHART_VERSION}" "${CHART_DIR}/Chart.yaml" \
  || fail "Chart.yaml flyte-binary dep != FLYTE_CHART_VERSION (${FLYTE_CHART_VERSION})"
# `helm push` derives the ECR repository from the chart name, so the chart must
# be named for the Marketplace-provisioned repository or it lands in a repo that
# does not exist and cannot be created.
# The EKS catalog name must agree with what the resolver queries for, or every
# deploy silently falls back to helm forever.
ADDON_NAME_IN_META="$(awk '/^  addOnName:/{print $2; exit}' "${METADATA}")"
[[ "${ADDON_PRODUCT_NAME}" == *"_${ADDON_NAME_IN_META}" ]] \
  || fail "ADDON_PRODUCT_NAME (${ADDON_PRODUCT_NAME}) does not end in _${ADDON_NAME_IN_META} from metadata.yaml addOnName"

MP_REPO_NAME="${MARKETPLACE_REPO##*/}"
grep -q "^name: ${MP_REPO_NAME}$" "${CHART_DIR}/Chart.yaml" \
  || fail "Chart.yaml name != Marketplace repository basename (${MP_REPO_NAME})"
echo "ok"

echo "== 2. vendor chart =="
"${REPO_ROOT}/scripts/vendor-chart.sh"

echo "== 3. helm lint =="
helm lint "${CHART_DIR}" -f "${CONFIG}"
HELM_V="$(helm version --template '{{.Version}}' | tr -d 'v')"
if [[ "$(printf '%s\n%s\n' "${HELM_MIN_VERSION}" "${HELM_V}" | sort -V | head -1)" != "${HELM_MIN_VERSION}" ]]; then
  echo "WARN: helm ${HELM_V} < ${HELM_MIN_VERSION}. Marketplace validates submitted"
  echo "      charts at ${HELM_MIN_VERSION}; build-addon.sh refuses to publish below it."
fi

echo "== 4. helm template renders =="
# The exact invocation Marketplace documents for add-on validation.
RENDERED="$(helm template flyte "${CHART_DIR}" \
  --kube-version "${EKS_K8S_VERSION}" \
  --namespace "${ADDON_NAMESPACE}" \
  --include-crds --no-hooks \
  -f "${CONFIG}")"
echo "${RENDERED}" | head -1 >/dev/null

# Marketplace validates a submitted chart by templating it with DEFAULT VALUES
# ONLY. Any `required` guard left unsatisfied by values.yaml fails ingestion with
# INVALID_HELM_TEMPLATE, no matter how complete the example config is. This is
# the exact command AWS documents, including the --set it passes.
echo "== 4b. helm template with DEFAULTS ONLY (what Marketplace runs) =="
helm template flyte-eks-add-on "${CHART_DIR}" \
  --set k8version="${EKS_K8S_VERSION}" \
  --kube-version "${EKS_K8S_VERSION}" \
  --namespace "${ADDON_NAMESPACE}" \
  --include-crds --no-hooks >/dev/null \
  || fail "chart does not render with default values — INVALID_HELM_TEMPLATE at ingestion"
echo "ok"

# Only .Release.Name and .Release.Namespace survive the add-on framework's
# conversion to plain manifests; anything else is INCOMPATIBLE_HELM_OBJECTS.
# vendor-chart.sh patches .Release.Service out of the upstream tree.
echo "== 4c. supported Helm release objects only =="
UNSUPPORTED="$(grep -rho '\.Release\.[A-Za-z]*' "${CHART_DIR}" 2>/dev/null \
  | sort -u | grep -vE '^\.Release\.(Name|Namespace)$' || true)"
[[ -z "${UNSUPPORTED}" ]] \
  || fail "unsupported Helm release objects in chart: $(echo "${UNSUPPORTED}" | tr '\n' ' ')"
echo "ok"

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

# The alias in Chart.yaml renames .Chart.Name inside the subchart; nameOverride
# has to pin the rendered names back or every consumer of flyte-flyte-binary-http
# breaks (smoke-test.sh, cloudformation/root.yaml, render-config.sh).
echo "${RENDERED}" | grep -q "name: flyte-flyte-binary-http" \
  || fail "flyte-flyte-binary-http not rendered — flyteBinary.nameOverride lost?"
# Only top-level metadata.name (2-space indent); CRD printer columns and env var
# names legitimately contain uppercase.
echo "${RENDERED}" | grep -qE "^  name: .*[A-Z]" \
  && fail "a rendered resource name contains uppercase (invalid DNS-1123)" || true

echo "== 6. Marketplace EKS add-on packaging rules =="

# 6a. The file AWS reads at ingestion, by exact name, at the chart top level.
[[ -f "${CHART_DIR}/aws_mp_configuration_schema.json" ]] \
  || fail "aws_mp_configuration_schema.json missing from the chart top level"
python3 -m json.tool "${CHART_DIR}/aws_mp_configuration_schema.json" >/dev/null \
  || fail "aws_mp_configuration_schema.json is not valid JSON"

# aws_mp_addon_parameters.json is deliberately ABSENT. Submitting it with an
# empty managedPolicies list was rejected with "Invalid Permissions List", and
# the only AWS-managed policy that functionally fits (AmazonS3FullAccess) grants
# account-wide S3, against the least-privilege requirement. See
# addon/chart/flyte-eks-add-on/README.md before adding it back.
[[ ! -f "${CHART_DIR}/aws_mp_addon_parameters.json" ]] \
  || fail "aws_mp_addon_parameters.json is back — see the chart README before shipping it"

# 6b. Schema draft must be one EKS accepts; anything else blocks release with
# INCOMPATIBLE_CONFIGURATION_SCHEMA_VERSION.
SCHEMA="${CHART_DIR}/aws_mp_configuration_schema.json"
python3 - "${SCHEMA}" <<'PY' || fail "configuration schema rejected"
import json, re, sys
s = json.load(open(sys.argv[1]))
ok = ("draft-04", "draft-06", "draft-07", "draft/2019-09")
uri = s.get("$schema", "")
if not any(d in uri for d in ok):
    sys.exit(f"$schema {uri!r} is not an EKS-supported draft {ok}")

# EKS requires camelCase configuration parameters and rejects the schema
# otherwise. Walk every declared property name.
bad, missing_desc = [], []
def walk(node, path=""):
    for name, sub in (node.get("properties") or {}).items():
        if not re.fullmatch(r"[a-z][A-Za-z0-9]*", name):
            bad.append(f"{path}{name}")
        if "description" not in sub:
            missing_desc.append(f"{path}{name}")
        walk(sub, f"{path}{name}.")
walk(s)
if bad:
    sys.exit("non-camelCase schema properties: " + ", ".join(bad))
if missing_desc:
    sys.exit("schema properties missing a description (rendered as EKS console "
             "field labels): " + ", ".join(missing_desc))

# INVALID_HELM_SENSITIVE_CONFIG: the config surface must not appear to collect
# secret material. Buyers pass the NAME of a pre-created Kubernetes Secret.
SECRETISH = re.compile(r"password|passwd|secret|apikey|api_key|token|certificate|privatekey", re.I)
leaks = []
def walk2(node, path=""):
    for name, sub in (node.get("properties") or {}).items():
        if SECRETISH.search(name) and not name.lower().endswith("name"):
            leaks.append(f"{path}{name}")
        walk2(sub, f"{path}{name}.")
walk2(s)
if leaks:
    sys.exit("schema declares secret-collecting fields: " + ", ".join(leaks))
# values.yaml ships deliberate placeholders for fields the upstream chart wraps
# in `required` (so it templates with defaults). The schema is what stops those
# placeholders reaching a cluster, so the required chain must stay intact.
need = {"": "flyteBinary", "flyteBinary": "configuration",
        "flyteBinary.configuration": "database",
        "flyteBinary.configuration.database": "postgres",
        "flyteBinary.configuration.database.postgres": "host",
        "flyteBinary.configuration.storage": "metadataContainer"}
def node_at(path):
    n = s
    for part in filter(None, path.split(".")):
        n = n["properties"][part]
    return n
for path, field in need.items():
    if field not in (node_at(path).get("required") or []):
        sys.exit(f"schema must mark {path + '.' if path else ''}{field} as required "
                 "(values.yaml ships a placeholder default for it)")
print("   schema ok (draft, camelCase, descriptions, no secret fields, required chain)")
PY

# 6c. Pod Identity declaration must name the same SA the chart creates and the
# CloudFormation PodIdentityAssociation binds.
SA_IN_CHART="$(grep -A3 '^  serviceAccount:' "${CHART_DIR}/values.yaml" | awk '/name:/{print $2; exit}')"
SA_IN_META="$(awk '/serviceAccountName:/{print $2; exit}' "${METADATA}")"
[[ "${SA_IN_CHART}" == "${SA_IN_META}" ]] \
  || fail "serviceAccount mismatch: chart=${SA_IN_CHART} metadata=${SA_IN_META}"
grep -A3 '^  serviceAccount:' "${CHART_DIR}/values.yaml" | grep -q "create: true" \
  || fail "serviceAccount.create must be true (a console-installed add-on attaches IAM to it)"

# 6d. Every image the chart renders must come from the Marketplace ECR with an
# explicit tag, and the set must match MP_IMAGES and metadata.yaml exactly.
# Mismatches here are INVALID_HELM_CHART_IMAGES / INVALID_HELM_UNDECLARED_IMAGES
# / MISSING_IMAGE_TAG at ingestion.
RENDERED_IMAGES="$(echo "${RENDERED}" | grep -Eo 'image: "?[^"]+' | sed 's/image: //; s/"//g' | sort -u)"
[[ -n "${RENDERED_IMAGES}" ]] || fail "no images found in rendered manifests"
while read -r img; do
  [[ "${img}" == "${MARKETPLACE_ECR}:"* ]] \
    || fail "image not in the Marketplace ECR: ${img}"
  [[ "${img##*:}" == "latest" ]] \
    && fail "image uses a floating 'latest' tag: ${img}" || true
done <<< "${RENDERED_IMAGES}"

EXPECTED_IMAGES="$(for row in "${MP_IMAGES[@]}"; do echo "${MARKETPLACE_ECR}:${row##*|}"; done | sort -u)"
diff <(echo "${EXPECTED_IMAGES}") <(echo "${RENDERED_IMAGES}") \
  || fail "rendered images do not match the MP_IMAGES table in versions.env"
METADATA_IMAGES="$(awk '/^  images:/{f=1;next} f&&/^    - /{print $2} f&&!/^    - /{exit}' "${METADATA}" | sort -u)"
diff <(echo "${EXPECTED_IMAGES}") <(echo "${METADATA_IMAGES}") \
  || fail "metadata.yaml images[] does not match MP_IMAGES (the Add Version request would be incomplete)"
echo "   images ok ($(echo "${RENDERED_IMAGES}" | wc -l | tr -d ' ') distinct, all in ${MARKETPLACE_ECR})"

# 6e. Unsupported Helm features. The add-on framework converts the chart to
# plain manifests: hooks and `lookup` never run, and .APIVersions is not
# available. Anything here fails with INCOMPATIBLE_HELM_OBJECTS.
grep -rn 'helm.sh/hook' "${CHART_DIR}" --include='*.yaml' --include='*.tpl' \
  && fail "chart uses Helm hooks — not supported by the EKS add-on framework" || true
grep -rn '{{-\? *lookup ' "${CHART_DIR}" --include='*.yaml' --include='*.tpl' \
  && fail "chart uses the lookup function — not supported by the EKS add-on framework" || true
# .APIVersions is supported for built-in Kubernetes APIs and only unsupported
# for custom ones, so flag the group rather than the call site.
python3 - "${CHART_DIR}" <<'PY' || fail "unsupported .Capabilities.APIVersions usage"
import pathlib, re, sys
BUILTIN = ("v1", "apps/", "rbac.authorization.k8s.io/", "batch/", "policy/",
           "networking.k8s.io/", "autoscaling/", "storage.k8s.io/",
           "apiextensions.k8s.io/", "admissionregistration.k8s.io/",
           "scheduling.k8s.io/", "coordination.k8s.io/", "discovery.k8s.io/",
           "node.k8s.io/", "certificates.k8s.io/", "events.k8s.io/",
           "authentication.k8s.io/", "authorization.k8s.io/",
           "flowcontrol.apiserver.k8s.io/")
bad = set()
for f in pathlib.Path(sys.argv[1]).rglob("*"):
    if f.suffix not in (".yaml", ".yml", ".tpl") or not f.is_file():
        continue
    text = f.read_text(errors="ignore")
    for api in re.findall(r'Capabilities\.APIVersions\.Has\s+"([^"]+)"', text):
        if not api.startswith(BUILTIN):
            bad.add(f"{api} ({f})")
    # A bare .APIVersions walk (range/toYaml) can't be checked for group, so
    # treat it as unsupported.
    if re.search(r'Capabilities\.APIVersions(?!\.Has)', text):
        bad.add(f"non-Has .APIVersions use ({f})")
if bad:
    sys.exit("unsupported .Capabilities.APIVersions on non-built-in APIs:\n  "
             + "\n  ".join(sorted(bad)))
print("   .Capabilities.APIVersions used only on built-in APIs")
PY

# 6f. Dependencies must live inside the chart. An https:// repository is
# INVALID_DEPENDENT_HELM_CHARTS even when the tarball happens to be vendored.
grep -E '^\s+repository:' "${CHART_DIR}/Chart.yaml" | grep -qv 'file://' \
  && fail "Chart.yaml has a non-file:// dependency repository" || true
[[ -f "${CHART_DIR}/charts/${FLYTE_CHART_NAME}/Chart.yaml" ]] \
  || fail "dependency not vendored at charts/${FLYTE_CHART_NAME}/"

# 6g. The framework tracks add-on rollout through a Deployment or DaemonSet.
echo "${RENDERED}" | grep -qE '^kind: (Deployment|DaemonSet)$' \
  || fail "no Deployment or DaemonSet rendered — the add-on would be untrackable"

echo "ALL CHECKS PASSED"

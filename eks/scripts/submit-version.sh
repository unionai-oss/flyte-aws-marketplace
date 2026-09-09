#!/usr/bin/env bash
# Submit a new add-on version to AWS Marketplace via the Catalog API.
#
# Everything the portal's "Add new version" form asks for lives in the repo:
# artifact URIs and add-on metadata in addon/metadata.yaml, copy in
# addon/listing/. This assembles them into an AddDeliveryOptions change set so
# a release is reviewed in a PR rather than retyped into a browser.
#
# Run scripts/build-addon.sh FIRST — the chart and images must already be in the
# Marketplace ECR, or ingestion fails on artifacts that do not exist.
#
# Usage:
#   AWS_REGION=us-east-1 scripts/submit-version.sh            # submit
#   DRY_RUN=1 scripts/submit-version.sh                       # print, submit nothing
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"
META="${REPO_ROOT}/addon/metadata.yaml"
LISTING="${REPO_ROOT}/addon/listing"
: "${MARKETPLACE_PRODUCT_ID:?MARKETPLACE_PRODUCT_ID is required (set in versions.env)}"
AWS_REGION="${AWS_REGION:-us-east-1}"

need() { command -v "$1" >/dev/null || { echo "$1 not found on PATH" >&2; exit 1; }; }
need aws; need python3

# Only one EKS add-on delivery option is allowed per version, and Marketplace
# refuses a new version while the previous one is still working its way to the
# EKS console. Catch that here rather than burning a chart tag on a rejection.
echo ">> checking for in-flight change sets on ${MARKETPLACE_PRODUCT_ID}"
INFLIGHT="$(aws marketplace-catalog list-change-sets --catalog AWSMarketplace \
  --region "${AWS_REGION}" \
  --filter-list "Name=EntityId,ValueList=${MARKETPLACE_PRODUCT_ID}" \
  --query "ChangeSetSummaryList[?Status=='APPLYING' || Status=='PREPARING'].ChangeSetId" \
  --output text 2>/dev/null || true)"
if [[ -n "${INFLIGHT}" ]]; then
  echo "FAIL: a change set is still in flight (${INFLIGHT})." >&2
  echo "      Wait for it to finish before submitting another version." >&2
  exit 1
fi

PAYLOAD="$(python3 - "${META}" "${LISTING}" "${ADDON_VERSION#v}" "${EKS_K8S_VERSION}" <<'PY'
import json, re, sys, pathlib
meta_path, listing, addon_version, k8s_version = sys.argv[1:5]
meta = pathlib.Path(meta_path).read_text()

def scalar(key):
    m = re.search(rf'^\s*{key}:\s*"?([^"\n]+)"?\s*$', meta, re.M)
    if not m: sys.exit(f"{key} not found in metadata.yaml")
    return m.group(1).strip()

images = re.findall(r'^\s+- (\S+dkr\.ecr\.\S+)$', meta, re.M)
if not images: sys.exit("no images[] found in metadata.yaml")

def text(name, limit):
    body = (pathlib.Path(listing) / name).read_text().strip()
    if len(body) > limit:
        sys.exit(f"{name} is {len(body)} chars, over the {limit} limit")
    return body

flyte_version = scalar("flyteVersion")
details = {
    "Version": {
        # Titles must be unique per version; a rejected submission still
        # consumes one, so track the add-on version rather than the Flyte one.
        "VersionTitle": f"Flyte {flyte_version} (add-on {addon_version})",
        "ReleaseNotes": text("release-notes.txt", 30000),
    },
    "DeliveryOptions": [{
        "DeliveryOptionTitle": text("delivery-option-title.txt", 100),
        "Visibility": "Limited",
        "Details": {
            "EksAddOnDeliveryOptionDetails": {
                "ContainerImages": images,
                "HelmChartUri": scalar("helmChartUri"),
                "Description": text("delivery-option-description.txt", 1000),
                "UsageInstructions": text("usage-instructions.txt", 4000),
                "AddOnName": scalar("addOnName"),
                "AddOnVersion": addon_version,
                "AddOnType": scalar("type"),
                "CompatibleKubernetesVersions": [k8s_version],
                "SupportedArchitectures": ["amd64", "arm64"],
                "Namespace": scalar("namespace"),
            }
        }
    }]
}
print(json.dumps(details))
PY
)"

CHANGE_SET="$(python3 -c '
import json, sys
details, product_id, version = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps([{
    "ChangeType": "AddDeliveryOptions",
    "Entity": {"Type": "ContainerProduct@1.0", "Identifier": product_id},
    "DetailsDocument": json.loads(details),
    "ChangeName": "AddEksAddOnVersion" + version.replace(".", ""),
}]))' "${PAYLOAD}" "${MARKETPLACE_PRODUCT_ID}" "${ADDON_VERSION#v}")"

echo ">> change set for ${MARKETPLACE_PRODUCT_ID}, add-on version ${ADDON_VERSION#v}:"
echo "${CHANGE_SET}" | python3 -m json.tool

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo ">> DRY_RUN=1 — not submitting."
  exit 0
fi

ID="$(aws marketplace-catalog start-change-set --catalog AWSMarketplace \
  --region "${AWS_REGION}" \
  --change-set-name "flyte-eks-add-on-${ADDON_VERSION#v}" \
  --change-set "${CHANGE_SET}" \
  --query ChangeSetId --output text)"

cat <<EOF

>> submitted: ${ID}
   Watch it with:
     aws marketplace-catalog describe-change-set --catalog AWSMarketplace \\
       --change-set-id ${ID} --region ${AWS_REGION} \\
       --query '{status:Status,errors:ChangeSet[].ErrorDetailList}'

   A rejection burns this chart tag: Marketplace ECR tags are immutable, so the
   next attempt needs scripts/bump-version.sh --addon <next> and a fresh
   scripts/build-addon.sh. See MARKETPLACE.md.
EOF

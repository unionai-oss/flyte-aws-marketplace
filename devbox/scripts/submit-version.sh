#!/usr/bin/env bash
# Submit a new devbox version to AWS Marketplace via the Catalog API.
#
# The devbox is an AmiProduct@1.0 with a CloudFormation delivery option, so a
# "version" is (AMI + template + listing copy) submitted together as one
# AddDeliveryOptions change set. Everything the portal's "Add new version" form
# asks for lives in the repo — copy in listing/, identity in versions.env, the
# AMI id in SSM — so a release is reviewed in a PR rather than retyped into a
# browser at 11pm.
#
# Run scripts/package-marketplace.sh FIRST: the template and diagram must already
# be in the seller bucket, or ingestion fails on assets that do not exist. That
# script writes .package-manifest.json, which this one reads for the versioned
# template URL, so the version you submit is the artifact you just uploaded
# rather than whatever "latest" happens to point at.
#
# Usage:
#   scripts/submit-version.sh                 # validate server-side, then submit
#   DRY_RUN=1 scripts/submit-version.sh       # print the change set, send nothing
#   VALIDATE_ONLY=1 scripts/submit-version.sh # run AWS's validation, create nothing
#
# VALIDATE_ONLY is worth the extra minute. It runs the same server-side checks as
# a real submission under Intent=VALIDATE without consuming a version title or
# producing a rejection on the listing's record.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"
LISTING="${REPO_ROOT}/listing"
MANIFEST="${REPO_ROOT}/.package-manifest.json"
AWS_REGION="${AWS_REGION:-us-east-1}"

: "${MARKETPLACE_PRODUCT_ID:?set MARKETPLACE_PRODUCT_ID in devbox/versions.env (the prod-... id from the portal URL)}"

need() { command -v "$1" >/dev/null || { echo "$1 not found on PATH" >&2; exit 1; }; }
need aws; need python3

# --- the artifacts -----------------------------------------------------------
# TEMPLATE_URL overrides the manifest, for submitting a template uploaded by an
# earlier run (or from another machine) without re-packaging.
if [[ -z "${TEMPLATE_URL:-}" ]]; then
  [[ -f "${MANIFEST}" ]] || {
    echo "FAIL: no ${MANIFEST} and no TEMPLATE_URL set." >&2
    echo "      Run scripts/package-marketplace.sh first, or pass TEMPLATE_URL=..." >&2
    exit 1; }
  TEMPLATE_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["template_url"])' "${MANIFEST}")"
  DIAGRAM_URL="${DIAGRAM_URL:-$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["diagram_url"])' "${MANIFEST}")}"
fi
: "${DIAGRAM_URL:?DIAGRAM_URL is required (normally read from the package manifest)}"

case "${TEMPLATE_URL}" in
  *flyte-devbox-latest.yaml)
    echo "FAIL: refusing to submit the 'latest' alias." >&2
    echo "      A listing must not change underneath a version AWS has reviewed." >&2
    echo "      Submit the versioned URL that package-marketplace.sh printed." >&2
    exit 1;;
esac

# --- the AMI -----------------------------------------------------------------
# Read it from SSM rather than taking it as an argument: the AMI pipeline writes
# that parameter only after the smoke test passes, so a submission cannot name an
# image that was never validated.
AMI_ID="${AMI_ID:-$(aws ssm get-parameter --name "${AMI_PARAM}" --region "${AWS_REGION}" \
                      --query Parameter.Value --output text)}"
[[ "${AMI_ID}" == ami-* ]] || { echo "FAIL: ${AMI_PARAM} holds '${AMI_ID}', not an AMI id" >&2; exit 1; }

# The Catalog API only exists in us-east-1 and only sees AMIs in the calling
# account there, so a copied-to-another-region AMI id fails ingestion with a
# confusing ASSET_NOT_FOUND. Catch it here instead.
aws ec2 describe-images --image-ids "${AMI_ID}" --region us-east-1 \
  --owners self --query 'Images[0].ImageId' --output text >/dev/null 2>&1 || {
  echo "FAIL: ${AMI_ID} is not an AMI owned by this account in us-east-1." >&2
  echo "      Marketplace ingests only from us-east-1 in the seller account." >&2
  exit 1; }

# --- in-flight check ---------------------------------------------------------
# Marketplace refuses a second version while one is still processing, and the
# rejection counts against the listing. Catch it before spending a version title.
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

# --- build the change set ----------------------------------------------------
# Version titles must be unique across the product's whole history and a REJECTED
# submission still consumes one, so it carries the AMI id: unique by construction,
# and it says which image a buyer is actually getting.
VERSION_TITLE="${VERSION_TITLE:-Flyte devbox ${AMI_ID}}"

# The generator goes to a temp file rather than a heredoc inside $(...): bash 3.2,
# which is what /bin/bash still is on macOS, mis-parses that combination.
GEN="$(mktemp -t devbox-changeset-XXXX.py)"
trap 'rm -f "${GEN}"' EXIT
cat > "${GEN}" <<'PY'
import json, pathlib, re, sys
(listing, product_id, version_title, template_url, diagram_url, ami_id,
 role_arn, user_name, os_name, os_version, instance_type, ami_param) = sys.argv[1:13]

# The Catalog API accepts an over-long or oddly-punctuated string happily and
# then fails the change set asynchronously, half an hour later, having consumed
# the version title. Enforce what the portal form enforces, up front.
def text(name, limit):
    body = (pathlib.Path(listing) / name).read_text().strip()
    if not body:
        sys.exit(f"{name} is empty")
    if len(body) > limit:
        sys.exit(f"{name} is {len(body)} chars, over the {limit} limit")
    # INVALID_* asynchronous errors, all avoidable. (A leading space is not
    # checked: .strip() above has already removed it.)
    if re.search(r'\s[™®]', body):
        sys.exit(f"{name} has a space before a trademark symbol")
    # AWS rejects "unsupported characters" asynchronously without saying which.
    # Em dashes and smart quotes are the usual culprits - they arrive by way of
    # a word processor and are invisible in a diff. Keep the copy ASCII.
    bad = sorted({c for c in body if ord(c) > 126})
    if bad:
        sys.exit(f"{name} has non-ASCII characters {bad} - replace them")
    return body

if len(version_title) > 255:
    sys.exit(f"version title is {len(version_title)} chars, over the 255 limit")

details = {
    "Version": {
        "VersionTitle": version_title,
        "ReleaseNotes": text("release-notes.txt", 30000),
    },
    "DeliveryOptions": [{
        "DeliveryOptionTitle": text("delivery-option-title.txt", 100),
        "Details": {
            "DeploymentTemplateDeliveryOptionDetails": {
                "ShortDescription": text("short-description.txt", 1000),
                "LongDescription": text("long-description.txt", 5000),
                "UsageInstructions": text("usage-instructions.txt", 4000),
                "RecommendedInstanceType": instance_type,
                "ArchitectureDiagram": diagram_url,
                "Template": template_url,
                # AWS injects this version's AMI id into the named template
                # parameter. It must be the only source of the image, which is
                # why package-marketplace.sh strips AmiSsmParameter.
                "TemplateSources": [{
                    "ParameterName": ami_param,
                    "AmiSource": {
                        "AmiId": ami_id,
                        "AccessRoleArn": role_arn,
                        "UserName": user_name,
                        "OperatingSystemName": os_name,
                        "OperatingSystemVersion": os_version,
                    },
                }],
            }
        },
    }],
}
print(json.dumps([{
    "ChangeType": "AddDeliveryOptions",
    "Entity": {"Type": "AmiProduct@1.0", "Identifier": product_id},
    "DetailsDocument": details,
    "ChangeName": "AddDevboxVersion",
}]))
PY

CHANGE_SET="$(python3 "${GEN}" "${LISTING}" "${MARKETPLACE_PRODUCT_ID}" "${VERSION_TITLE}" \
                "${TEMPLATE_URL}" "${DIAGRAM_URL}" "${AMI_ID}" "${AMI_INGESTION_ROLE_ARN}" \
                "${AMI_USER_NAME}" "${AMI_OS_NAME}" "${AMI_OS_VERSION}" \
                "${RECOMMENDED_INSTANCE_TYPE}" "${AMI_TEMPLATE_PARAMETER}")"

echo ">> change set for ${MARKETPLACE_PRODUCT_ID}"
echo "   version:  ${VERSION_TITLE}"
echo "   ami:      ${AMI_ID}"
echo "   template: ${TEMPLATE_URL}"
echo "${CHANGE_SET}" | python3 -m json.tool

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo ">> DRY_RUN=1 — not submitting."
  exit 0
fi

submit() {  # $1 = Intent
  aws marketplace-catalog start-change-set --catalog AWSMarketplace \
    --region "${AWS_REGION}" \
    --change-set-name "flyte-devbox-${AMI_ID}" \
    --change-set "${CHANGE_SET}" \
    --intent "$1" \
    --query ChangeSetId --output text
}

# Intent=VALIDATE runs AWS's own checks without creating the version. Always do
# it first — it costs a minute and catches the mistakes that otherwise surface
# as an asynchronous rejection against a version title that is now spent.
echo ">> validating (Intent=VALIDATE)"
VALIDATE_ID="$(submit VALIDATE)"
echo "   validation change set: ${VALIDATE_ID}"
aws marketplace-catalog describe-change-set --catalog AWSMarketplace \
  --region "${AWS_REGION}" --change-set-id "${VALIDATE_ID}" \
  --query '{status:Status,errors:ChangeSet[].ErrorDetailList}' --output json

if [[ "${VALIDATE_ONLY:-0}" == "1" ]]; then
  echo ">> VALIDATE_ONLY=1 — validation submitted, no version created."
  echo "   Validation is asynchronous; poll the change set above until it leaves PREPARING."
  exit 0
fi

echo ">> submitting (Intent=APPLY)"
ID="$(submit APPLY)"

cat <<EOF

>> submitted: ${ID}
   Watch it with:
     aws marketplace-catalog describe-change-set --catalog AWSMarketplace \\
       --change-set-id ${ID} --region ${AWS_REGION} \\
       --query '{status:Status,errors:ChangeSet[].ErrorDetailList}'

   Validation takes minutes to hours. A rejection consumes the version title
   "${VERSION_TITLE}" permanently — the next attempt needs a new AMI or an
   explicit VERSION_TITLE. See MARKETPLACE.md.
EOF

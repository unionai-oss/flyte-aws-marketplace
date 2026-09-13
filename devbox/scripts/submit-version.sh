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
# TWO MODES, because AWS requires every VERSION of an AMI product to carry a
# DISTINCT AMI id. Submitting a new version against an AMI already used by an
# existing version is rejected with "Duplicate AMI id", so a template- or
# copy-only change cannot be a new version at all:
#
#   MODE=add     a genuinely new version: new AMI + template + copy, sent as
#                AddDeliveryOptions. Needs an AMI id no version has used.
#   MODE=update  change the template, diagram or listing copy of an EXISTING
#                version in place, sent as UpdateDeliveryOptions. Touches no AMI
#                and consumes no version title.
#   MODE=auto    (default) ask the listing which of those is legal and do that.
#
# auto is not a guess. AWS decides it: if the AMI we would submit is already used
# by an existing version, "add" is not a choice that exists - it is rejected as a
# duplicate - so the only legal action is to update that version. If the AMI is
# new to the listing, "add" is correct. So auto reads the versions off the
# listing, looks for our AMI id, and picks accordingly. It refuses to guess when
# it cannot read them, rather than defaulting to one and hoping.
#
# Usage:
#   scripts/submit-version.sh                    # figure it out
#   MODE=update scripts/submit-version.sh        # force: retarget an existing version
#   MODE=add scripts/submit-version.sh           # force: new version
#   DRY_RUN=1 scripts/submit-version.sh          # print the change set, send nothing
#   VALIDATE_ONLY=1 scripts/submit-version.sh    # run AWS's validation, create nothing
#
# VALIDATE_ONLY is worth the extra minute in ADD mode: it runs the same
# server-side checks as a real submission under Intent=VALIDATE without
# consuming a version title. It does not exist in update mode - AWS rejects
# Intent for UpdateDeliveryOptions - where DRY_RUN=1 is the dry run instead.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"
LISTING="${REPO_ROOT}/listing"
MANIFEST="${REPO_ROOT}/.package-manifest.json"
AWS_REGION="${AWS_REGION:-us-east-1}"
MODE="${MODE:-auto}"
case "${MODE}" in add|update|auto) ;; *) echo "MODE must be 'add', 'update' or 'auto', got '${MODE}'" >&2; exit 1;; esac

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
# Read from SSM rather than taken as an argument: the AMI pipeline writes that
# parameter only after the smoke test passes, so a submission cannot name an
# image that was never validated. Needed in add mode to submit, and in auto mode
# to work out whether the listing has already used it. Update mode never sends
# it - the AMI of an existing version is exactly what must not change.
if [[ "${MODE}" != "update" ]]; then
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
fi

# --- resolve the mode and the update target ----------------------------------
# One DescribeEntity serves both jobs: deciding add-vs-update, and finding the
# entity identifier (with its @version suffix) and delivery option id that
# UpdateDeliveryOptions has to address. The response is walked tolerantly rather
# than by a fixed path, and printed, so an unexpected shape is visible instead of
# silently producing a change set aimed at the wrong thing.
if [[ "${MODE}" != "add" ]]; then
  echo ">> describing ${MARKETPLACE_PRODUCT_ID}"
  ENTITY_JSON="$(aws marketplace-catalog describe-entity --catalog AWSMarketplace \
    --region "${AWS_REGION}" --entity-id "${MARKETPLACE_PRODUCT_ID}" --output json)"

  DISCOVERED="$(python3 "${REPO_ROOT}/scripts/describe-entity.py" "${ENTITY_JSON}" "${AMI_ID:-}")"
  echo "${DISCOVERED}" | python3 -m json.tool

  if [[ "${MODE}" == "auto" ]]; then
    RESOLVED="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["resolution"])' "${DISCOVERED}")"
    case "${RESOLVED}" in
      add)
        MODE=add
        echo ">> auto: ${AMI_ID} is not on any existing version - adding a new one";;
      update)
        MODE=update
        echo ">> auto: ${AMI_ID} is already on an existing version, so a new version would be";
        echo "   rejected as a duplicate - updating that version in place instead";;
      *)
        echo "FAIL: cannot tell whether ${AMI_ID:-<no ami>} is already on a version." >&2
        echo "      Reason: ${RESOLVED}" >&2
        echo "      The DescribeEntity result above is what it had to work with." >&2
        echo "      Re-run with MODE=add or MODE=update once you have decided." >&2
        exit 1;;
    esac
  fi
fi

if [[ "${MODE}" == "update" ]]; then
  # Override either if the discovery picks wrong.
  ENTITY_IDENTIFIER="${ENTITY_IDENTIFIER:-$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["entity_identifier"] or "")' "${DISCOVERED}")}"
  DELIVERY_OPTION_ID="${DELIVERY_OPTION_ID:-$(python3 -c 'import json,sys;print(json.loads(sys.argv[1])["target_option_id"] or "")' "${DISCOVERED}")}"

  [[ -n "${ENTITY_IDENTIFIER}" ]] || {
    echo "FAIL: could not read the entity identifier from DescribeEntity." >&2
    echo "      Pass ENTITY_IDENTIFIER=<prod-id>@<version> explicitly." >&2; exit 1; }
  [[ -n "${DELIVERY_OPTION_ID}" ]] || {
    echo "FAIL: could not pick a CloudFormation delivery option automatically." >&2
    echo "      The listing above shows what DescribeEntity returned; choose one and" >&2
    echo "      pass DELIVERY_OPTION_ID=<id> (and ENTITY_IDENTIFIER if it is not the" >&2
    echo "      version you want)." >&2; exit 1; }
  echo "   entity:          ${ENTITY_IDENTIFIER}"
  echo "   delivery option: ${DELIVERY_OPTION_ID}"
fi

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
# Unset in update mode, where neither is used. Defaulted so `set -u` does not
# trip on the references below.
AMI_ID="${AMI_ID:-}"
VERSION_TITLE="${VERSION_TITLE:-Flyte devbox ${AMI_ID}}"
CHANGE_SET_NAME="flyte-devbox-${AMI_ID}"
if [[ "${MODE}" == "update" ]]; then
  CHANGE_SET_NAME="flyte-devbox-update-$(date +%Y%m%d%H%M%S)"
fi

# The generator goes to a temp file rather than a heredoc inside $(...): bash 3.2,
# which is what /bin/bash still is on macOS, mis-parses that combination.
GEN="$(mktemp -t devbox-changeset-XXXX.py)"
trap 'rm -f "${GEN}"' EXIT
cat > "${GEN}" <<'PY'
import json, pathlib, re, sys
(listing, product_id, version_title, template_url, diagram_url, ami_id,
 role_arn, user_name, os_name, os_version, instance_type, ami_param,
 mode, entity_identifier, delivery_option_id) = sys.argv[1:16]

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

# Everything both modes send. Update mode omits TemplateSources entirely: the
# AMI on an existing version must not change, and sending it back is what AWS
# rejects as "Duplicate AMI id".
option_title = text("delivery-option-title.txt", 100)
template_details = {
    "ShortDescription": text("short-description.txt", 1000),
    "LongDescription": text("long-description.txt", 5000),
    "UsageInstructions": text("usage-instructions.txt", 4000),
    "RecommendedInstanceType": instance_type,
    "ArchitectureDiagram": diagram_url,
    "Template": template_url,
}

if mode == "update":
    # UpdateDeliveryOptions carries no VersionTitle - it edits a version that
    # already has one - so there is no title to collide and none to consume.
    print(json.dumps([{
        "ChangeType": "UpdateDeliveryOptions",
        "Entity": {"Type": "AmiProduct@1.0", "Identifier": entity_identifier},
        "DetailsDocument": {
            "Version": {"ReleaseNotes": text("release-notes.txt", 30000)},
            "DeliveryOptions": [{
                "Id": delivery_option_id,
                # Update puts the title INSIDE the details object.
                "Details": {"DeploymentTemplateDeliveryOptionDetails": dict(
                    template_details, DeliveryOptionTitle=option_title)},
            }],
        },
        "ChangeName": "UpdateDevboxDeliveryOption",
    }]))
    raise SystemExit(0)

if len(version_title) > 255:
    sys.exit(f"version title is {len(version_title)} chars, over the 255 limit")

details = {
    "Version": {
        "VersionTitle": version_title,
        "ReleaseNotes": text("release-notes.txt", 30000),
    },
    "DeliveryOptions": [{
        # Add puts the title at the delivery-option level, not in the details.
        "DeliveryOptionTitle": option_title,
        "Details": {
            "DeploymentTemplateDeliveryOptionDetails": dict(template_details, **{
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
            })
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
                "${RECOMMENDED_INSTANCE_TYPE}" "${AMI_TEMPLATE_PARAMETER}" \
                "${MODE}" "${ENTITY_IDENTIFIER:-}" "${DELIVERY_OPTION_ID:-}")"

echo ">> ${MODE} change set for ${MARKETPLACE_PRODUCT_ID}"
if [[ "${MODE}" == "add" ]]; then
  echo "   version:  ${VERSION_TITLE}"
  echo "   ami:      ${AMI_ID}"
else
  echo "   entity:   ${ENTITY_IDENTIFIER}   (AMI unchanged)"
fi
echo "   template: ${TEMPLATE_URL}"
echo "${CHANGE_SET}" | python3 -m json.tool

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo ">> DRY_RUN=1 — not submitting."
  exit 0
fi

# Intent is accepted per change type, not per API. AWS rejects it outright for
# UpdateDeliveryOptions on AmiProduct@1.0 -
#   "Intent not supported for change type 'UpdateDeliveryOptions'"
# - so update mode has to submit with no --intent at all, and gets no
# server-side rehearsal. Pass "" to omit it.
submit() {  # $1 = Intent, or "" for none
  local intent=()
  [[ -n "$1" ]] && intent=(--intent "$1")
  # ${arr[@]+...} because bash 3.2 (macOS) treats an empty array as unbound
  # under `set -u`.
  aws marketplace-catalog start-change-set --catalog AWSMarketplace \
    --region "${AWS_REGION}" \
    --change-set-name "${CHANGE_SET_NAME}" \
    --change-set "${CHANGE_SET}" \
    ${intent[@]+"${intent[@]}"} \
    --query ChangeSetId --output text
}

if [[ "${MODE}" == "add" ]]; then
  # Intent=VALIDATE runs AWS's own checks without creating the version. Always do
  # it first in add mode - it costs a minute and catches the mistakes that
  # otherwise surface as an asynchronous rejection against a version title that
  # is now spent.
  echo ">> validating (Intent=VALIDATE)"
  VALIDATE_ID="$(submit VALIDATE)"
  echo "   validation change set: ${VALIDATE_ID}"
  aws marketplace-catalog describe-change-set --catalog AWSMarketplace \
    --region "${AWS_REGION}" --change-set-id "${VALIDATE_ID}" \
    --query '{status:Status,errors:ChangeSet[].ErrorDetailList}' --output json

  if [[ "${VALIDATE_ONLY:-0}" == "1" ]]; then
    echo ">> VALIDATE_ONLY=1 - validation submitted, no version created."
    echo "   Validation is asynchronous; poll the change set above until it leaves PREPARING."
    exit 0
  fi

  echo ">> submitting (Intent=APPLY)"
  ID="$(submit APPLY)"
else
  if [[ "${VALIDATE_ONLY:-0}" == "1" ]]; then
    cat >&2 <<'NOVALIDATE'
>> VALIDATE_ONLY is not available in update mode. NOTHING WAS SUBMITTED.

   AWS does not accept Intent for UpdateDeliveryOptions on AmiProduct@1.0, so
   there is no server-side rehearsal for this change type.

   Use DRY_RUN=1 to inspect the exact change set without sending it, then re-run
   without VALIDATE_ONLY to apply.

   Update is the cheap direction: it consumes no version title, so a rejection
   can be corrected and resubmitted against the same version.
NOVALIDATE
    exit 0
  fi

  echo ">> submitting (no Intent - not supported for UpdateDeliveryOptions)"
  ID="$(submit "")"
fi

cat <<EOF

>> submitted: ${ID}
   Watch it with:
     aws marketplace-catalog describe-change-set --catalog AWSMarketplace \\
       --change-set-id ${ID} --region ${AWS_REGION} \\
       --query '{status:Status,errors:ChangeSet[].ErrorDetailList}'

   Review takes minutes to hours.
   ${MODE} mode: $( [[ "${MODE}" == "add" ]] \
     && echo "a rejection consumes the version title \"${VERSION_TITLE}\" permanently - the next attempt needs a new AMI or an explicit VERSION_TITLE." \
     || echo "no version title is consumed; a rejection can be corrected and resubmitted against the same version." )
   See MARKETPLACE.md.
EOF

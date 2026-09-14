#!/usr/bin/env bash
# Point the AWS Marketplace listing at the logo in this repo.
#
# The listing logo is product metadata, not part of a version, so it changes via
# the UpdateInformation change type rather than AddDeliveryOptions - and unlike
# a template change it needs no new AMI and consumes no version title. A logo-only
# update is allowed: "when you are updating existing fields on the product, you
# can include only the attributes that need to be changed".
#
# LogoUrl must be a publicly readable HTTPS URL. package-marketplace.sh uploads
# listing/logo.png to the seller asset bucket (devbox/* is public-read) and
# records the result in .package-manifest.json, which this reads.
#
# This is deliberately NOT part of submit-version.sh: Marketplace processes one
# change set at a time per product, so bundling a metadata change with a version
# submission would make each one able to block the other.
#
# Usage:
#   scripts/package-marketplace.sh && scripts/set-listing-logo.sh
#   DRY_RUN=1 scripts/set-listing-logo.sh     # print the change set, send nothing
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"
# shellcheck source=scripts/lib-catalog.sh
source "${REPO_ROOT}/scripts/lib-catalog.sh"
MANIFEST="${REPO_ROOT}/.package-manifest.json"
AWS_REGION="${AWS_REGION:-us-east-1}"

: "${MARKETPLACE_PRODUCT_ID:?set MARKETPLACE_PRODUCT_ID in devbox/versions.env}"
need() { command -v "$1" >/dev/null || { echo "$1 not found on PATH" >&2; exit 1; }; }
need aws; need python3

if [[ -z "${LOGO_URL:-}" ]]; then
  [[ -f "${MANIFEST}" ]] || {
    echo "FAIL: no ${MANIFEST} and no LOGO_URL set." >&2
    echo "      Run scripts/package-marketplace.sh first, or pass LOGO_URL=..." >&2
    exit 1; }
  LOGO_URL="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("logo_url") or "")' "${MANIFEST}")"
fi
[[ -n "${LOGO_URL}" ]] || { echo "FAIL: no logo_url in the manifest; re-run package-marketplace.sh" >&2; exit 1; }

# AWS validates this pattern at StartChangeSet, so a bad URL fails the call
# rather than the listing. Check it here to keep the error close to the cause.
python3 - "${LOGO_URL}" <<'PYEOF'
import re, sys
url = sys.argv[1]
if not re.match(r'^https://(www\.)?[-a-zA-Z0-9@.]{1,256}\.[a-zA-Z0-9()]{2,63}\b([-a-zA-Z0-9@+./]*)$', url):
    sys.exit(f"LogoUrl does not match the pattern AWS enforces: {url}")
PYEOF

# The logo must be readable by anyone, or ingestion cannot fetch it.
echo ">> checking ${LOGO_URL} is publicly readable"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${LOGO_URL}" 2>/dev/null || echo 000)"
[[ "${code}" == "200" ]] || { echo "FAIL: unauthenticated GET returned ${code}, expected 200." >&2; exit 1; }

refuse_if_change_set_in_flight "${MARKETPLACE_PRODUCT_ID}" || exit 1

CHANGE_SET="$(python3 -c '
import json, sys
print(json.dumps([{
    "ChangeType": "UpdateInformation",
    "Entity": {"Type": "AmiProduct@1.0", "Identifier": sys.argv[1]},
    "DetailsDocument": {"LogoUrl": sys.argv[2]},
    "ChangeName": "UpdateDevboxLogo",
}]))' "${MARKETPLACE_PRODUCT_ID}" "${LOGO_URL}")"

echo ">> UpdateInformation for ${MARKETPLACE_PRODUCT_ID}"
echo "${CHANGE_SET}" | python3 -m json.tool

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo ">> DRY_RUN=1 — not submitting."
  exit 0
fi

ID="$(aws marketplace-catalog start-change-set --catalog AWSMarketplace \
  --region "${AWS_REGION}" \
  --change-set-name "flyte-devbox-logo-$(date +%Y%m%d%H%M%S)" \
  --change-set "${CHANGE_SET}" \
  --query ChangeSetId --output text)"

echo ">> submitted: ${ID} — waiting"
rc=0; wait_for_change_set "${ID}" "${APPLY_TIMEOUT:-1800}" "logo update" || rc=$?
case "${rc}" in
  0) echo ">> DONE. The listing logo now points at ${LOGO_URL}" ;;
  2) echo ">> still processing; check with describe-change-set --change-set-id ${ID}" ;;
  *) echo "FAIL: the logo update did not succeed; errors above." >&2
     echo "      Nothing else changed - metadata updates consume no version title." >&2
     exit 1 ;;
esac

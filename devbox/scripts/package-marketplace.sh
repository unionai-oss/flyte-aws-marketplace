#!/usr/bin/env bash
# Package the devbox stack for the AWS Marketplace listing and upload it, plus
# the architecture diagram, to the seller account's asset bucket.
#
# Produces a MARKETPLACE VARIANT of cloudformation/root.yaml rather than shipping
# it as-is, because two things the repo wants for its own deploys are the two
# things Marketplace rejects:
#
# 1. AmiSsmParameter
#      Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
#      Default: /flyte-devbox/ami/latest
#    CloudFormation resolves SSM-parameter-typed parameters in the account
#    running the stack, whether or not the value is referenced. Buyers have no
#    /flyte-devbox/ami/latest, so every launch would fail at parameter
#    resolution — even though Marketplace populates AmiId and HasAmiId would have
#    made the SSM value irrelevant. Dropped here; ImageId falls back to AmiId
#    alone, which Marketplace always supplies.
#
# 2. Nested-stack TemplateURLs
#    root.yaml points at ../../common/... and templates/... so that
#    `aws cloudformation package` resolves them for our own deploys. But package
#    rewrites them to hardcoded S3 URLs, and Marketplace rejects those: the URLs
#    must be built from three named parameters — MPS3BucketName, MPS3BucketRegion,
#    MPS3KeyPrefix — whose defaults AWS rewrites when it copies the nested
#    templates into its own bucket. So this script uploads the nested templates
#    under stable names and rewrites the URLs itself, instead of calling package.
#
# Nothing else is uploaded on the seller's behalf: every Lambda in the stack is
# inline (ZipFile). Marketplace neither ingests nor scans seller S3 objects and
# counts them as an external dependency, which is why the Cognito branding Lambda
# and its logo were replaced by a native CSS-only UICustomizationAttachment.
#
# Usage:
#   AWS_PROFILE=union-seller scripts/package-marketplace.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUCKET="${MARKETPLACE_ASSET_BUCKET:-flyte-marketplace-assets-747712783559}"
REGION="${AWS_REGION:-us-east-1}"
# Must end in "/" — it is concatenated directly onto the object key in the !Sub.
KEY_PREFIX="devbox/templates/"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Nested templates: "<path relative to root.yaml>|<name it is uploaded under>".
# The uploaded name is what the rewritten TemplateURL resolves to, so these must
# stay in step with the TemplateURL values in root.yaml.
NESTED=(
  "../../common/cloudformation/data.yaml|data.yaml"
  "../../common/cloudformation/auth.yaml|auth.yaml"
  "templates/compute.yaml|compute.yaml"
)

echo ">> [1/4] rewrite root.yaml into the buyer-facing variant"
python3 - "${REPO_ROOT}/cloudformation/root.yaml" "${WORK}/root.yaml" \
         "${BUCKET}" "${REGION}" "${KEY_PREFIX}" <<'PY'
import os, re, sys
src, dst, bucket, region, prefix = sys.argv[1:6]
t = open(src).read()

# --- 1. AmiSsmParameter -----------------------------------------------------
# Drop the parameter block: from its key to the next top-level-ish key.
before = t
t = re.sub(r'\n  AmiSsmParameter:\n(?:    .*\n|\n(?=    ))*', '\n', t)
if t == before:
    sys.exit("AmiSsmParameter block not found — did root.yaml change?")

# With the parameter gone, ImageId comes from AmiId alone.
before = t
t = t.replace('ImageId: !If [HasAmiId, !Ref AmiId, !Ref AmiSsmParameter]',
              'ImageId: !Ref AmiId')
if t == before:
    sys.exit("ImageId !If not found — did root.yaml change?")

# AmiId is now required rather than an optional override, so say so.
t = t.replace(
    'Pin a specific Flyte devbox AMI ID. Leave blank to use the latest AMI\n'
    '      published by the build pipeline (resolved from AmiSsmParameter at deploy time).',
    'The Flyte devbox AMI. AWS Marketplace populates this automatically with the\n'
    '      AMI for your Region; there is no need to change it.')

if 'AmiSsmParameter' in t:
    sys.exit("AmiSsmParameter still referenced after rewrite:\n" +
             "\n".join(l for l in t.splitlines() if 'AmiSsmParameter' in l))

# HasAmiId existed only to choose between AmiId and the SSM parameter. With the
# latter gone it is an unused condition, so drop it rather than hand the
# reviewer dead logic.
before = t
t = t.replace('  HasAmiId: !Not [!Equals [!Ref AmiId, ""]]\n', '')
if t == before:
    sys.exit("HasAmiId condition not found — did root.yaml change?")
if 'HasAmiId' in t:
    sys.exit("HasAmiId still referenced after rewrite")

# --- 2. Nested-stack TemplateURLs -------------------------------------------
# AWS Marketplace requires these exact parameter names, and rewrites their
# defaults to point at its own copy of the templates once the version is
# submitted. Until then the defaults have to resolve to the seller bucket, which
# must be publicly readable.
mp_params = (
    '  # --- AWS Marketplace nested-template location ---\n'
    '  # AWS rewrites these three defaults when it copies the nested templates\n'
    '  # into its own bucket at submission time. The names are fixed by AWS.\n'
    '  MPS3BucketName:\n'
    '    Type: String\n'
    f'    Default: {bucket}\n'
    '    Description: S3 bucket holding the nested templates.\n'
    '  MPS3BucketRegion:\n'
    '    Type: String\n'
    f'    Default: {region}\n'
    '    Description: Region of the S3 bucket holding the nested templates.\n'
    '  MPS3KeyPrefix:\n'
    '    Type: String\n'
    f'    Default: {prefix}\n'
    '    Description: S3 key prefix (a trailing "/" is required) for the nested templates.\n'
)

if not t.startswith('AWSTemplateFormatVersion'):
    sys.exit("unexpected template header")
if '\nParameters:\n' not in t:
    sys.exit("no Parameters block found")
t = t.replace('\nParameters:\n', '\nParameters:\n' + mp_params, 1)

# Group them in the console the way the AWS example does.
interface = (
    'Metadata:\n'
    '  AWS::CloudFormation::Interface:\n'
    '    ParameterGroups:\n'
    '      - Label:\n'
    '          default: AWS Marketplace Parameters\n'
    '        Parameters:\n'
    '          - AmiId\n'
    '          - MPS3BucketName\n'
    '          - MPS3BucketRegion\n'
    '          - MPS3KeyPrefix\n'
    '\n'
)
t = t.replace('\nParameters:\n', '\n' + interface + 'Parameters:\n', 1)

def to_mp_url(m):
    name = os.path.basename(m.group(2))
    return (m.group(1) + '!Sub https://${MPS3BucketName}.s3.${MPS3BucketRegion}'
            '.${AWS::URLSuffix}/${MPS3KeyPrefix}' + name)

t, n = re.subn(r'(\n\s+TemplateURL: )(\S+\.yaml)', to_mp_url, t)
if n != 3:
    sys.exit(f"expected 3 nested TemplateURLs, rewrote {n} — did root.yaml change?")

open(dst, 'w').write(t)
print(f"   stripped AmiSsmParameter; rewrote {n} nested TemplateURLs via MPS3* parameters")
PY

echo ">> [2/4] upload nested templates to s3://${BUCKET}/${KEY_PREFIX}"
for row in "${NESTED[@]}"; do
  rel="${row%%|*}"; name="${row##*|}"
  src="${REPO_ROOT}/cloudformation/${rel}"
  [[ -f "${src}" ]] || { echo "missing nested template: ${src}" >&2; exit 1; }
  aws cloudformation validate-template --template-body "file://${src}" \
    --region "${REGION}" >/dev/null \
    || { echo "nested template failed validate-template: ${name}" >&2; exit 1; }
  aws s3 cp "${src}" "s3://${BUCKET}/${KEY_PREFIX}${name}" --region "${REGION}" >/dev/null
  echo "   ${name}"
done

echo ">> [3/4] validate + upload the root template"
aws cloudformation validate-template \
  --template-body "file://${WORK}/root.yaml" --region "${REGION}" >/dev/null \
  || { echo "root template failed validate-template" >&2; exit 1; }

VERSION="$(date +%Y%m%d%H%M%S)"
aws s3 cp "${WORK}/root.yaml" "s3://${BUCKET}/devbox/flyte-devbox-${VERSION}.yaml" \
  --region "${REGION}" >/dev/null
aws s3 cp "${WORK}/root.yaml" "s3://${BUCKET}/devbox/flyte-devbox-latest.yaml" \
  --region "${REGION}" >/dev/null

echo ">> [4/4] upload the architecture diagram"
if [[ -f "${REPO_ROOT}/docs/architecture.png" ]]; then
  aws s3 cp "${REPO_ROOT}/docs/architecture.png" "s3://${BUCKET}/devbox/architecture.png" \
    --region "${REGION}" >/dev/null
  echo "   uploaded architecture.png"
else
  echo "   SKIP: devbox/docs/architecture.png not found"
fi

BASE="https://${BUCKET}.s3.${REGION}.amazonaws.com"
cat <<EOF

>> Listing URLs:
   CloudFormation template : ${BASE}/devbox/flyte-devbox-${VERSION}.yaml
   (stable alias)          : ${BASE}/devbox/flyte-devbox-latest.yaml
   Architecture diagram    : ${BASE}/devbox/architecture.png

   Submit the VERSIONED template url, not the alias — a listing should not
   change underneath a version that AWS already reviewed.

   These objects must be readable by AWS Marketplace, and the nested templates
   under ${KEY_PREFIX} must be publicly readable at review time. See MARKETPLACE.md.
EOF

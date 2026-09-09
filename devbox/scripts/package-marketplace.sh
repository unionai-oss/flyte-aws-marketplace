#!/usr/bin/env bash
# Package the devbox stack for the AWS Marketplace listing and upload it, plus
# the architecture diagram, to the seller account's asset bucket.
#
# Produces a MARKETPLACE VARIANT of cloudformation/root.yaml rather than
# shipping it as-is. The difference is one parameter:
#
#   AmiSsmParameter:
#     Type: AWS::SSM::Parameter::Value<AWS::EC2::Image::Id>
#     Default: /flyte-devbox/ami/latest
#
# CloudFormation resolves SSM-parameter-typed parameters in the account running
# the stack, whether or not the value is referenced. Buyers have no
# /flyte-devbox/ami/latest, so every launch would fail at parameter resolution —
# even though Marketplace populates AmiId and HasAmiId would have made the SSM
# value irrelevant. The parameter is dropped here and ImageId falls back to
# AmiId alone, which Marketplace always supplies.
#
# root.yaml keeps the SSM indirection for our own deploys: it is what lets the
# AMI pipeline publish a new image without a template change.
#
# Usage:
#   AWS_PROFILE=union-seller scripts/package-marketplace.sh
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUCKET="${MARKETPLACE_ASSET_BUCKET:-flyte-marketplace-assets-747712783559}"
REGION="${AWS_REGION:-us-east-1}"
WORK="$(mktemp -d)"
# The stripped template must sit NEXT TO root.yaml: `cloudformation package`
# resolves nested TemplateURL paths relative to the template's own directory,
# so building it in a temp dir breaks ../../common/cloudformation/*.yaml.
VARIANT="${REPO_ROOT}/cloudformation/.marketplace-root.yaml"
trap 'rm -rf "${WORK}" "${VARIANT}"' EXIT

echo ">> [1/3] strip AmiSsmParameter for the buyer-facing template"
python3 - "${REPO_ROOT}/cloudformation/root.yaml" "${VARIANT}" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()

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
open(dst, 'w').write(t)
print("   stripped AmiSsmParameter; ImageId now !Ref AmiId")
PY

echo ">> [2/3] package nested stacks into s3://${BUCKET}/devbox/templates"
aws cloudformation package \
  --template-file "${VARIANT}" \
  --s3-bucket "${BUCKET}" --s3-prefix devbox/templates \
  --region "${REGION}" \
  --output-template-file "${WORK}/packaged.yaml" >/dev/null

aws cloudformation validate-template \
  --template-body "file://${WORK}/packaged.yaml" --region "${REGION}" >/dev/null \
  || { echo "packaged template failed validate-template" >&2; exit 1; }

VERSION="$(date +%Y%m%d%H%M%S)"
aws s3 cp "${WORK}/packaged.yaml" "s3://${BUCKET}/devbox/flyte-devbox-${VERSION}.yaml" \
  --region "${REGION}" >/dev/null
aws s3 cp "${WORK}/packaged.yaml" "s3://${BUCKET}/devbox/flyte-devbox-latest.yaml" \
  --region "${REGION}" >/dev/null

echo ">> [3/3] upload the architecture diagram"
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
   must be readable by BUYERS at launch time. See MARKETPLACE.md.
EOF

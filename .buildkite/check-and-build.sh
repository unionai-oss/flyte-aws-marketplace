#!/usr/bin/env bash
# Release-detection gate for the devbox AMI build pipeline.
#
# Compares the current Flyte devbox image digest (cr.flyte.org:latest) to the
# digest the last published AMI was built from (SSM /flyte-devbox/ami/source-digest).
# On a scheduled build this makes the pipeline a no-op until a new devbox release
# ships; when the digest changes it uploads the build -> smoke -> publish steps.
#
# Force a rebuild regardless (e.g. after a packer/template change) with the
# Buildkite build env var FORCE_BUILD=true.
set -euo pipefail

IMAGE="${DEVBOX_IMAGE:-cr.flyte.org/flyteorg/flyte-devbox:latest}"
DIGEST_PARAM="${SOURCE_DIGEST_PARAM:-/flyte-devbox/ami/source-digest}"

# Canonical, machine-independent registry digest of the (multi-arch) image.
CURRENT=$(docker buildx imagetools inspect "$IMAGE" | awk '/^Digest:/{print $2; exit}')
[ -n "$CURRENT" ] || { echo "ERROR: could not resolve digest for $IMAGE" >&2; exit 1; }

PUBLISHED=$(aws ssm get-parameter --name "$DIGEST_PARAM" --query Parameter.Value --output text 2>/dev/null || echo "none")

echo "devbox image:     $IMAGE"
echo "current digest:   $CURRENT"
echo "published digest: $PUBLISHED"

if [ "${FORCE_BUILD:-false}" != "true" ] && [ "$CURRENT" = "$PUBLISHED" ]; then
  echo "No new devbox release — nothing to build."
  exit 0
fi

echo "New devbox release (or FORCE_BUILD=true) — queuing build + publish."
buildkite-agent meta-data set "source_digest" "$CURRENT"
buildkite-agent pipeline upload .buildkite/build-publish.yml

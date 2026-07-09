#!/usr/bin/env bash
# Emit a path-filtered Buildkite pipeline on stdout. Uploaded by pipeline.yml.
#
# A change under common/** re-validates BOTH products (the shared data + auth
# substrate is nested by each). Repo-wide files do the same. On main we also
# append the devbox AMI release-check.
set -euo pipefail

DEFAULT_BRANCH="${BUILDKITE_PIPELINE_DEFAULT_BRANCH:-main}"
BRANCH="${BUILDKITE_BRANCH:-}"

# Determine the changed files for this build.
if [ "$BRANCH" = "$DEFAULT_BRANCH" ]; then
  BASE="HEAD~1"
else
  git fetch -q origin "$DEFAULT_BRANCH" 2>/dev/null || true
  BASE="origin/${DEFAULT_BRANCH}"
fi
CHANGED="$(git diff --name-only "${BASE}...HEAD" 2>/dev/null || git diff --name-only "$BASE" 2>/dev/null || true)"

changed() { printf '%s\n' "$CHANGED" | grep -qE "$1"; }

devbox=false; eks=false
# No diff resolvable (first build / shallow clone) -> validate everything.
if [ -z "${CHANGED//[[:space:]]/}" ]; then
  devbox=true; eks=true
else
  changed '^devbox/' && devbox=true
  changed '^eks/'    && eks=true
  # Shared substrate or repo-wide files affect both products.
  if changed '^common/' || changed '^scripts/' || changed '^\.buildkite/' || changed '^\.cfnlintrc'; then
    devbox=true; eks=true
  fi
fi

echo "steps:"

if $devbox; then
  cat <<'YAML'
  - label: ":mag: devbox static validation"
    key: devbox-validate
    command: |
      python3 -m pip install --quiet --upgrade cfn-lint flyte
      ./devbox/scripts/validate.sh
    agents:
      queue: "default"
YAML
fi

if $eks; then
  cat <<'YAML'
  - label: ":mag: eks static validation"
    key: eks-validate
    command: ./eks/scripts/validate.sh
    agents:
      queue: "default"
YAML
fi

# Build/publish only from the default branch (incl. scheduled builds); PRs stop
# at validation. Detects a new devbox image and, on one, builds + smoke-tests +
# publishes the AMI (see check-and-build.sh -> build-publish.yml).
if [ "$BRANCH" = "$DEFAULT_BRANCH" ]; then
  cat <<'YAML'
  - wait: ~
  - label: ":mag: check for new devbox release"
    key: check-release
    command: ./.buildkite/check-and-build.sh
    agents:
      queue: "aws"
YAML
fi

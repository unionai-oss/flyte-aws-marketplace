#!/usr/bin/env bash
# Bump the pinned versions across every file that carries them.
#
# Version strings are duplicated on purpose — versions.env is the source of
# truth, but Chart.yaml, metadata.yaml and values.yaml each need literals that
# helm and the Marketplace portal read directly. validate.sh asserts they agree;
# this script is what keeps them agreeing.
#
# Usage:
#   scripts/bump-version.sh --flyte v2.0.28      # new upstream flyte-binary chart
#   scripts/bump-version.sh --addon 0.1.3        # new add-on packaging revision
#   scripts/bump-version.sh --flyte v2.0.28 --addon 0.2.0
#
# Bumping --flyte alone does NOT bump the add-on version; a new upstream chart
# always needs a new add-on version too, so CI passes both.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="${REPO_ROOT}/addon/chart/flyte-eks-add-on/Chart.yaml"
VALUES="${REPO_ROOT}/addon/chart/flyte-eks-add-on/values.yaml"
META="${REPO_ROOT}/addon/metadata.yaml"
ENVF="${REPO_ROOT}/versions.env"

NEW_FLYTE=""; NEW_ADDON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flyte) NEW_FLYTE="$2"; shift 2 ;;
    --addon) NEW_ADDON="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "${NEW_FLYTE}" || -n "${NEW_ADDON}" ]] || { echo "nothing to bump" >&2; exit 2; }

source "${ENVF}"
OLD_FLYTE="${FLYTE_CHART_VERSION}"
OLD_ADDON="${ADDON_VERSION#v}"

sedi() { sed -i.bak -E "$1" "$2" && rm -f "$2.bak"; }

if [[ -n "${NEW_FLYTE}" ]]; then
  [[ "${NEW_FLYTE}" == v* ]] || { echo "--flyte must look like v2.0.28" >&2; exit 2; }
  echo ">> flyte-binary ${OLD_FLYTE} -> ${NEW_FLYTE}"
  sedi "s|^FLYTE_CHART_VERSION=\".*\"$|FLYTE_CHART_VERSION=\"${NEW_FLYTE}\"|" "${ENVF}"
  sedi "s|^    version: ${OLD_FLYTE}$|    version: ${NEW_FLYTE}|" "${CHART}"
  sedi "s|^appVersion: \".*\"$|appVersion: \"${NEW_FLYTE#v}\"|" "${CHART}"
  sedi "s|^  flyteVersion: \".*\"$|  flyteVersion: \"${NEW_FLYTE#v}\"|" "${META}"
  # Image tags carry the upstream version. A new upstream image has never been
  # pushed, so its relocation revision restarts at r1 (see MP_IMAGES).
  sedi "s|flyte-binary-${OLD_FLYTE}-r[0-9]+|flyte-binary-${NEW_FLYTE}-r1|g" "${VALUES}"
  sedi "s|flyte-binary-${OLD_FLYTE}-r[0-9]+|flyte-binary-${NEW_FLYTE}-r1|g" "${META}"
fi

if [[ -n "${NEW_ADDON}" ]]; then
  NEW_ADDON="${NEW_ADDON#v}"
  echo ">> add-on ${OLD_ADDON} -> ${NEW_ADDON}"
  sedi "s|^ADDON_VERSION=\".*\"$|ADDON_VERSION=\"v${NEW_ADDON}\"|" "${ENVF}"
  sedi "s|^version: ${OLD_ADDON}$|version: ${NEW_ADDON}|" "${CHART}"
  sedi "s|^  version: \"${OLD_ADDON}\"$|  version: \"${NEW_ADDON}\"|" "${META}"
  sedi "s|(flyte-eks-add-on):${OLD_ADDON}$|\1:${NEW_ADDON}|" "${META}"
fi

echo ">> done. Run scripts/validate.sh to confirm every pin still agrees."

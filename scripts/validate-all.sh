#!/usr/bin/env bash
# Static validation for the whole monorepo: the shared common/ templates plus
# both products (devbox + eks). No AWS credentials required. A change under
# common/** affects both products, so CI runs this on any common/** change.
#
# Usage: scripts/validate-all.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
hr() { printf '\n########## %s ##########\n' "$1"; }

hr "common/ CloudFormation (data + auth)"
if command -v cfn-lint >/dev/null 2>&1; then
  if cfn-lint --config-file "${REPO_ROOT}/.cfnlintrc" "${REPO_ROOT}/common/cloudformation/"*.yaml; then
    echo "  common templates lint clean"
  else
    echo "  common templates FAILED cfn-lint"; fail=1
  fi
else
  echo "  SKIP: cfn-lint not installed (pip install cfn-lint)"
fi

hr "devbox"
"${REPO_ROOT}/devbox/scripts/validate.sh" || fail=1

hr "eks"
"${REPO_ROOT}/eks/scripts/validate.sh" || fail=1

echo
if [ "$fail" = 0 ]; then
  printf '\033[32mAll monorepo static checks passed.\033[0m\n'
else
  printf '\033[31mMonorepo static validation FAILED.\033[0m\n'
fi
exit "$fail"

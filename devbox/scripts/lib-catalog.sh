#!/usr/bin/env bash
# Shared AWS Marketplace Catalog API helpers.
#
# Sourced, never executed. Both scripts that talk to the Catalog API need the
# same two things - refuse to start while another change set is processing, and
# wait for the one we submitted to reach a terminal state - and two copies would
# drift.
#
# Expects AWS_REGION to be set by the caller.

# Poll a change set to a terminal state and say what happened.
#
# AWS validates asynchronously. This used to fire VALIDATE and then immediately
# APPLY, which made the rehearsal decoration - the result arrived long after the
# version had been created. Now validation actually gates the submission.
#
# Returns 0 SUCCEEDED, 1 FAILED/CANCELLED, 2 still running at the timeout.
wait_for_change_set() {   # <id> <timeout seconds> <label>
  local id="$1" timeout="$2" label="$3" waited=0 status
  while :; do
    status="$(aws marketplace-catalog describe-change-set --catalog AWSMarketplace \
      --region "${AWS_REGION}" --change-set-id "${id}" --query Status --output text)"
    case "${status}" in
      PREPARING|APPLYING) ;;
      *) break ;;
    esac
    if [[ "${waited}" -ge "${timeout}" ]]; then
      echo "   ${label}: still ${status} after ${timeout}s" >&2
      return 2
    fi
    sleep 15
    waited=$(( waited + 15 ))
    [[ $(( waited % 60 )) -eq 0 ]] && echo "   ${label}: ${status} (${waited}s)"
  done
  echo "   ${label}: ${status}"
  if [[ "${status}" != "SUCCEEDED" ]]; then
    echo "   errors:" >&2
    aws marketplace-catalog describe-change-set --catalog AWSMarketplace \
      --region "${AWS_REGION}" --change-set-id "${id}" \
      --query 'ChangeSet[].ErrorDetailList' --output json >&2
    return 1
  fi
  return 0
}

# Marketplace refuses a second change set while one is still processing, and the
# rejection counts against the listing. Catch it before spending anything.
refuse_if_change_set_in_flight() {   # <entity id>
  local entity="$1" inflight
  echo ">> checking for in-flight change sets on ${entity}"
  inflight="$(aws marketplace-catalog list-change-sets --catalog AWSMarketplace \
    --region "${AWS_REGION}" \
    --filter-list "Name=EntityId,ValueList=${entity}" \
    --query "ChangeSetSummaryList[?Status=='APPLYING' || Status=='PREPARING'].ChangeSetId" \
    --output text 2>/dev/null || true)"
  if [[ -n "${inflight}" ]]; then
    echo "FAIL: a change set is still in flight (${inflight})." >&2
    echo "      Wait for it to finish before submitting another." >&2
    return 1
  fi
}

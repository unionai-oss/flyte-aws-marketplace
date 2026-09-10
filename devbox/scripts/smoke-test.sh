#!/usr/bin/env bash
# Integration smoke test: deploy a throwaway Prod stack, authenticate via the
# Cognito M2M client (no browser), run a workflow, then deploy an app built from
# a NON-DEFAULT (custom) image and assert it serves publicly at its
# *.apps.<Domain> URL, then tear everything down. Spends real AWS money — run
# manually / from the Buildkite "aws" queue. Idempotent teardown via EXIT trap.
#
# The app step exercises the whole app path the workflow step doesn't: image
# build + push to the stack ECR, the cluster's ECR pull (kubelet credential
# provider), Knative/Kourier config-domain, and *.apps.<Domain> ALB routing.
# It needs docker on the runner; without docker the app step is skipped (loudly).
#
# Required env (defaults target the Marketplace SELLER account, 747712783559):
#   DOMAIN          fully-qualified name for the test stack (its Route 53 zone is
#                   auto-discovered by the template — no zone id needed)
#
#                   The default sits under mp.flytedemo.app, a zone delegated to
#                   the seller account so CI never deploys into anyone's personal
#                   namespace. Override DOMAIN to run against a zone you own.
# Optional:
#   STACK_NAME (default flyte-devbox-smoke)  REGION (us-east-1)
#   AWS_PROFILE (unset => ambient creds)     AMI_ID (override template default)
set -euo pipefail

STACK_NAME="${STACK_NAME:-flyte-devbox-smoke}"
REGION="${REGION:-us-east-1}"
DOMAIN="${DOMAIN:-smoke.mp.flytedemo.app}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/cloudformation/root.yaml"
AWSP=(); [ -n "${AWS_PROFILE:-}" ] && AWSP=(--profile "$AWS_PROFILE")
aws_() { aws "${AWSP[@]}" --region "$REGION" "$@"; }

log() { printf '\n\033[36m▶ %s\033[0m\n' "$*"; }

teardown() {
  if [ "${KEEP:-0}" = "1" ]; then
    log "KEEP=1 — leaving $STACK_NAME up for inspection (delete it manually when done)"; return
  fi
  log "Teardown: deleting $STACK_NAME"
  BUCKET=$(aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text 2>/dev/null || true)
  [ -n "${BUCKET:-}" ] && [ "$BUCKET" != "None" ] && aws_ s3 rb "s3://$BUCKET" --force >/dev/null 2>&1 || true
  aws_ cloudformation delete-stack --stack-name "$STACK_NAME" >/dev/null 2>&1 || true
  aws_ cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" 2>/dev/null || true
  # Delete resources whose DeletionPolicy is Retain/Snapshot — they survive the
  # stack and, having deterministic names (${StackName}-flyte, -flyte-data),
  # would make the NEXT run's CREATE change-set fail. Best-effort.
  for r in $(aws_ ecr describe-repositories --query "repositories[?starts_with(repositoryName, '${STACK_NAME}-flyte/')].repositoryName" --output text 2>/dev/null); do
    aws_ ecr delete-repository --repository-name "$r" --force >/dev/null 2>&1 || true
  done
  aws_ backup delete-backup-vault --backup-vault-name "${STACK_NAME}-flyte-data" >/dev/null 2>&1 || true
  log "Teardown complete"
}
trap teardown EXIT

# Nested stack: the root references templates/compute.yaml + the shared
# common/{data,auth} templates, so we `aws cloudformation package` them to S3.
ACCOUNT=$(aws_ sts get-caller-identity --query Account --output text)
S3_BUCKET="${S3_BUCKET:-cf-templates-flyte-devbox-${ACCOUNT}-${REGION}}"
aws_ s3api head-bucket --bucket "$S3_BUCKET" 2>/dev/null || aws_ s3 mb "s3://$S3_BUCKET" >/dev/null

log "Deploying $STACK_NAME ($DOMAIN) — Prod mode"
# Clean any prior instance of this throwaway stack first (so CREATE is valid).
if aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  aws_ cloudformation delete-stack --stack-name "$STACK_NAME"
  aws_ cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" 2>/dev/null || true
fi
# Also clear Retain/Snapshot resources a prior (or KEEP=1) run may have left —
# their deterministic names would otherwise make the CREATE change-set fail.
aws_ ecr delete-repository --repository-name "${STACK_NAME}-flyte" --force >/dev/null 2>&1 || true
aws_ backup delete-backup-vault --backup-vault-name "${STACK_NAME}-flyte-data" >/dev/null 2>&1 || true
aws_ s3 rb "s3://${STACK_NAME}-flyte-${ACCOUNT}-${REGION}" --force >/dev/null 2>&1 || true
# Package the nested templates to S3, then create-change-set + execute (more
# robust than `cloudformation deploy`, whose early-validation hook is flaky).
PACKAGED="$(mktemp -t packaged-XXXX.yaml)"
aws_ cloudformation package --template-file "$TEMPLATE" \
  --s3-bucket "$S3_BUCKET" --s3-prefix "smoke-${STACK_NAME}" \
  --output-template-file "$PACKAGED" >/dev/null
aws_ s3 cp "$PACKAGED" "s3://$S3_BUCKET/smoke-${STACK_NAME}.yaml" >/dev/null
aws_ cloudformation create-change-set --stack-name "$STACK_NAME" --change-set-name smoke \
  --change-set-type CREATE --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --template-url "https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/smoke-${STACK_NAME}.yaml" \
  --parameters ParameterKey=Domain,ParameterValue="$DOMAIN" \
    ParameterKey=AllowedCidr,ParameterValue=0.0.0.0/0 \
    ParameterKey=AutoStop,ParameterValue=No \
    ParameterKey=AmiId,ParameterValue="${AMI_ID:-}" >/dev/null
aws_ cloudformation wait change-set-create-complete --stack-name "$STACK_NAME" --change-set-name smoke
aws_ cloudformation execute-change-set --stack-name "$STACK_NAME" --change-set-name smoke
aws_ cloudformation wait stack-create-complete --stack-name "$STACK_NAME"

ENDPOINT="dns:///${DOMAIN}:443"
POOL=$(aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='CognitoUserPoolId'].OutputValue" --output text)
M2M=$(aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" --query "Stacks[0].Outputs[?OutputKey=='CognitoM2MClientId'].OutputValue" --output text)
COG_DOMAIN="https://${STACK_NAME}-${ACCOUNT}.auth.${REGION}.amazoncognito.com"
SECRET=$(aws_ cognito-idp describe-user-pool-client --user-pool-id "$POOL" --client-id "$M2M" --query "UserPoolClient.ClientSecret" --output text)

log "Waiting for the devbox to answer authenticated gRPC (cold boot ~5 min)"
TOK=""
for i in $(seq 1 60); do
  TOK=$(curl -s -X POST "$COG_DOMAIN/oauth2/token" -u "$M2M:$SECRET" \
        -d "grant_type=client_credentials&scope=https://${DOMAIN}/access" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null || true)
  if [ -n "$TOK" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
      "https://${DOMAIN}/flyteidl2.project.ProjectService/ListProjects" \
      -H "content-type: application/proto" -H "authorization: Bearer $TOK" --data-binary "" || true)
    echo "  attempt $i: ListProjects -> $code"
    [ "$code" = "200" ] && break
  fi
  sleep 15
done
[ "${code:-}" = "200" ] || { echo "devbox never became healthy"; exit 1; }

log "Running a workflow via M2M auth"
WORK="$(mktemp -d)"; cat > "$WORK/hello.py" <<'PY'
import flyte
env = flyte.TaskEnvironment(name="smoke")
@env.task
def main() -> str:
    return "smoke ok"
PY
cat > "$WORK/.config.yaml" <<YAML
admin:
  authType: ExternalCommand
  command: ["echo", "$TOK"]
  endpoint: $ENDPOINT
image:
  builder: local
task:
  project: flytesnacks
  domain: development
YAML

FLYTE="${FLYTE_BIN:-flyte}"
# On a brand-new box the data-proxy/storage subsystem can lag a little behind the
# API answering ListProjects, so give it a warm-up buffer + retry the run.
log "Warming up before run..."
sleep 45
OK=0
for attempt in 1 2 3 4; do
  OUT=$(cd "$WORK" && "$FLYTE" --config .config.yaml run hello.py main 2>&1) || true
  if echo "$OUT" | grep -q "Created Run:"; then OK=1; break; fi
  echo "  run attempt $attempt did not create a run; retrying in 20s"
  echo "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | tail -4
  sleep 20
done
echo "$OUT" | sed 's/\x1b\[[0-9;]*m//g' | tail -8
if [ "$OK" = 1 ]; then
  log "✅ Workflow run created"
else
  log "❌ SMOKE FAILED — no run created after retries"; exit 1
fi

# ---------------------------------------------------------------------------
# App test: custom-built (non-default) image -> stack ECR -> Knative serving.
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "⚠️  docker not available — SKIPPING app test (custom image build needs docker)"
  log "✅ SMOKE PASSED — workflow run (app portion skipped)"
  exit 0
fi

APP_NAME="smoke-app"
ECR=$(aws_ cloudformation describe-stacks --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='ProdImageRegistry'].OutputValue" --output text)
ECR_HOST="${ECR%%/*}"   # <acct>.dkr.ecr.<region>.amazonaws.com
NS="${ECR#*/}"          # <stack>-flyte  (namespace after the host)

log "Docker login to the stack ECR ($ECR_HOST)"
aws_ ecr get-login-password | docker login --username AWS --password-stdin "$ECR_HOST" >/dev/null 2>&1

# Unique per-run image NAME (not just tag) so we exercise ECR create-on-push:
# the SDK pushes <namespace>/<name> to a repo that does not exist yet, and the
# stack's repository creation template auto-creates it. Also defeats flyte's
# build-skip cache (a fresh name every run guarantees a real build+push).
RUN_ID=$(date +%s)-$$
IMG_NAME="smoke-${RUN_ID}"

cat > "$WORK/app.py" <<PY
import flyte, flyte.app
# The app just needs to listen on 8080 and answer 200 so we can prove the whole
# path (custom image -> ECR create-on-push -> Knative -> ALB). Use the stdlib
# directory server: its argv has only clean tokens, which matters because flyte
# round-trips app args through shlex+shell (a python -c one-liner gets mangled).
# It serves 200 at '/', which is what we poll, and listening satisfies Knative's
# readiness probe. .with_pip_packages forces a real (non-default) image build;
# the custom image name pushes to a NEW ECR repo (auto-created on push).
image = flyte.Image.from_debian_base(
    python_version=(3, 12), registry="$ECR", name="$IMG_NAME",
    platform=("linux/amd64",),
).with_pip_packages("httpx").with_env_vars({"SMOKE_BUILD_ID": "$RUN_ID"})
app_env = flyte.app.AppEnvironment(
    name="$APP_NAME", image=image, args="python3 -m http.server 8080",
    port=8080, resources=flyte.Resources(cpu="1", memory="512Mi"), requires_auth=False,
)
PY

log "Deploying app (build custom image -> create-on-push to ECR -> register)"
if (cd "$WORK" && "$FLYTE" --config .config.yaml deploy app.py app_env) >"$WORK/deploy.log" 2>&1; then
  sed 's/\x1b\[[0-9;]*m//g' "$WORK/deploy.log" | tail -4
else
  sed 's/\x1b\[[0-9;]*m//g' "$WORK/deploy.log" | tail -12
  log "❌ APP SMOKE FAILED — deploy (build/push/register) errored"; exit 1
fi

# Guard: confirm create-on-push auto-created the repo AND the image landed
# (catches a silent build-skip, which otherwise surfaces only as a Knative
# image-pull 404 later).
if [ "$(aws_ ecr list-images --repository-name "${NS}/${IMG_NAME}" --query 'length(imageIds)' --output text 2>/dev/null)" = "0" ]; then
  log "❌ APP SMOKE FAILED — image not auto-created/pushed to ${NS}/${IMG_NAME}"; exit 1
fi

# Public URL is <app>-<project>-<domain>.apps.<Domain> (Knative ksvc name). Poll
# it: 200 proves the cluster pulled the ECR image, the revision is Ready, and the
# *.apps ALB rule + wildcard cert/DNS route to it.
APP_URL="https://${APP_NAME}-flytesnacks-development.apps.${DOMAIN}/"
log "Polling app URL (Knative cold start + ECR pull): $APP_URL"
acode=""
for i in $(seq 1 30); do
  acode=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$APP_URL" || true)
  echo "  attempt $i: $acode"
  [ "$acode" = "200" ] && break
  sleep 10
done
if [ "$acode" = "200" ]; then
  log "✅ SMOKE PASSED — workflow run + custom-image app served at $APP_URL"
else
  log "❌ APP SMOKE FAILED — app never served 200 (last: $acode)"; exit 1
fi

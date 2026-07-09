#!/usr/bin/env bash
# Fast dev loop: push a changed baked file from packer/files/ onto a running
# devbox instance (via SSM, no SSH key) and restart the affected service — so you
# can iterate on the product scripts without rebuilding the AMI. Bake for real by
# rebuilding the AMI (packer build) once you're happy.
#
# Usage:
#   scripts/dev-sync.sh <stack-name|instance-id> <file>
#   e.g. scripts/dev-sync.sh flyte-devbox-prod idle-agent.py
# Env: REGION (us-east-1), AWS_PROFILE (optional).
set -euo pipefail

TARGET="${1:?stack name or instance-id}"
FILE="${2:?file basename in packer/files/}"
REGION="${REGION:-us-east-1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/packer/files/$FILE"
[ -f "$SRC" ] || { echo "no such file: $SRC"; exit 1; }
AWSP=(); [ -n "${AWS_PROFILE:-}" ] && AWSP=(--profile "$AWS_PROFILE")
aws_() { aws "${AWSP[@]}" --region "$REGION" "$@"; }

# dest path + service to restart, per file
case "$FILE" in
  render-override.sh)     DEST=/usr/local/bin/flyte-render-override.sh;  MODE=755; SVC=flyte-devbox ;;
  render-appdomain.sh)    DEST=/usr/local/bin/flyte-render-appdomain.sh; MODE=755; SVC=flyte-appdomain ;;
  gpu-setup.sh)           DEST=/opt/flyte-devbox/gpu-setup.sh;           MODE=755; SVC="" ;;
  idle-agent.py)          DEST=/opt/flyte-idle-agent/flyte_idle_agent.py; MODE=755; SVC=flyte-idle-agent ;;
  # Restarting flyte-devbox reapplies the traefik access-log manifest.
  traefik-accesslog.yaml) DEST=/opt/flyte-devbox/traefik-accesslog.yaml; MODE=644; SVC=flyte-devbox ;;
  *) echo "unknown file mapping for $FILE"; exit 1 ;;
esac

case "$TARGET" in
  i-*) IID="$TARGET" ;;
  *)   IID=$(aws_ cloudformation describe-stacks --stack-name "$TARGET" \
         --query "Stacks[0].Outputs[?OutputKey=='InstanceId'].OutputValue" --output text) ;;
esac
echo "→ $FILE → $IID:$DEST (restart: ${SVC:-none})"

B64=$(base64 < "$SRC" | tr -d '\n')
RESTART=""; [ -n "$SVC" ] && RESTART="systemctl restart $SVC.service && echo restarted $SVC"
CMD=$(aws_ ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript --timeout-seconds 120 \
  --parameters "commands=[\"echo $B64 | base64 -d > $DEST\",\"chmod $MODE $DEST\",\"$RESTART\"]" \
  --query Command.CommandId --output text)
until S=$(aws_ ssm get-command-invocation --command-id "$CMD" --instance-id "$IID" --query Status --output text 2>/dev/null); [ "$S" = Success ] || [ "$S" = Failed ]; do sleep 3; done
echo "status=$S"
aws_ ssm get-command-invocation --command-id "$CMD" --instance-id "$IID" --query StandardOutputContent --output text
[ "$S" = Success ]

#!/usr/bin/env bash
# In-cluster bootstrap, run by the CloudFormation CodeBuild project against the
# freshly-created EKS cluster. Everything that must happen *inside* the cluster
# (and can't be a plain CFN resource) lives here so it stays testable as a
# script rather than buried in an inline buildspec.
#
# Responsibilities:
#   1. kubeconfig for the new cluster
#   2. create the flyte namespace + the DB password Secret (from Secrets Manager)
#   3. (prod) install the AWS Load Balancer Controller + its IAM (Pod Identity)
#   4. (prod) issue the ACM cert and DNS-validate it via Route 53
#   5. install Flyte via the resolver (add-on if published, else helm) — the same
#      scripts/resolve-install.sh used everywhere
#   6. (prod) point Route 53 at the ingress ALB
#
# Inputs (env), provided by CodeBuild from CloudFormation outputs:
#   AWS_REGION CLUSTER_NAME NAMESPACE SERVICE_ACCOUNT
#   DB_SECRET_ARN DB_HOST DB_PORT DB_NAME DB_USER S3_BUCKET
#   FLYTE_S3_ROLE_ARN
#   DOMAIN_NAME HOSTED_ZONE_ID           (prod mode; empty => dev mode)
#   COGNITO_ISSUER COGNITO_CLIENT_ID     (prod mode)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/versions.env"

: "${AWS_REGION:?}" "${CLUSTER_NAME:?}" "${DB_SECRET_ARN:?}"
: "${DB_HOST:?}" "${S3_BUCKET:?}" "${FLYTE_S3_ROLE_ARN:?}"
NAMESPACE="${NAMESPACE:-${ADDON_NAMESPACE}}"
SERVICE_ACCOUNT="${SERVICE_ACCOUNT:-flyte-backend}"
PROD_MODE=false
[[ -n "${DOMAIN_NAME:-}" ]] && PROD_MODE=true

# Log to stderr so functions whose stdout is captured with $(...) (e.g.
# issue_certificate) don't leak log lines into the captured value.
log() { echo ">> [bootstrap] $*" >&2; }

# --- 1. kubeconfig -----------------------------------------------------------
log "configuring kubeconfig for ${CLUSTER_NAME}"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${CLUSTER_NAME}"

# --- 2. namespace + DB secret ------------------------------------------------
log "creating namespace ${NAMESPACE} and DB credential secret"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
DB_PASSWORD="$(aws secretsmanager get-secret-value --region "${AWS_REGION}" \
  --secret-id "${DB_SECRET_ARN}" --query SecretString --output text \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])')"
# The chart reads the password file at configuration.database.postgres.passwordPath
# (/etc/db/secret/password), mounted from this secret's `password` key.
kubectl -n "${NAMESPACE}" create secret generic flyte-db-credentials \
  --from-literal=password="${DB_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset DB_PASSWORD

# Task service account. Tasks run under this (executor.defaultK8sServiceAccount
# in the chart values); it's bound to the S3 role via the CloudFormation
# PodIdentityAssociation. The SA must exist before task pods schedule, and the
# chart does not create it, so we do it here.
log "creating task service account ${TASK_SERVICE_ACCOUNT:-flyte-task}"
kubectl -n "${NAMESPACE}" create serviceaccount "${TASK_SERVICE_ACCOUNT:-flyte-task}" \
  --dry-run=client -o yaml | kubectl apply -f -

# --- 3. AWS Load Balancer Controller (prod only) -----------------------------
install_lb_controller() {
  local policy_arn role_name role_arn account
  account="$(aws sts get-caller-identity --query Account --output text)"
  role_name="${CLUSTER_NAME}-alb-controller"
  log "ensuring ALB controller IAM policy + role"
  policy_arn="$(aws iam list-policies --scope Local \
    --query "Policies[?PolicyName=='${CLUSTER_NAME}-AWSLoadBalancerControllerIAMPolicy'].Arn" \
    --output text)"
  if [[ -z "${policy_arn}" || "${policy_arn}" == "None" ]]; then
    policy_arn="$(aws iam create-policy \
      --policy-name "${CLUSTER_NAME}-AWSLoadBalancerControllerIAMPolicy" \
      --policy-document "file://${REPO_ROOT}/cloudformation/policies/alb-controller-iam.json" \
      --query Policy.Arn --output text)"
  fi
  if ! aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    aws iam create-role --role-name "${role_name}" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"pods.eks.amazonaws.com"},"Action":["sts:AssumeRole","sts:TagSession"]}]}'
  fi
  aws iam attach-role-policy --role-name "${role_name}" --policy-arn "${policy_arn}"
  role_arn="arn:aws:iam::${account}:role/${role_name}"

  log "binding ALB controller SA via Pod Identity"
  if ! aws eks list-pod-identity-associations --region "${AWS_REGION}" \
      --cluster-name "${CLUSTER_NAME}" --namespace kube-system \
      --query "associations[?serviceAccount=='aws-load-balancer-controller']" \
      --output text | grep -q .; then
    aws eks create-pod-identity-association --region "${AWS_REGION}" \
      --cluster-name "${CLUSTER_NAME}" --namespace kube-system \
      --service-account aws-load-balancer-controller --role-arn "${role_arn}"
  fi

  # On a freshly-created cluster the EKS Pod Identity Agent DaemonSet may not be
  # running yet; without it the controller can't obtain credentials. Wait for it
  # before installing (this race is what stalled early bootstrap attempts).
  log "waiting for eks-pod-identity-agent daemonset"
  kubectl -n kube-system rollout status daemonset/eks-pod-identity-agent --timeout=5m || true

  local vpc_id
  vpc_id="$(aws eks describe-cluster --region "${AWS_REGION}" --name "${CLUSTER_NAME}" \
    --query cluster.resourcesVpcConfig.vpcId --output text)"

  log "helm install aws-load-balancer-controller (vpc ${vpc_id})"
  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo update >/dev/null
  # Install without --wait, then gate on an explicit rollout so a stall produces
  # actionable diagnostics in the build log instead of a bare "context deadline".
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName="${CLUSTER_NAME}" \
    --set region="${AWS_REGION}" \
    --set vpcId="${vpc_id}" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller
  if ! kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=5m; then
    log "ALB controller did not become ready — diagnostics:"
    kubectl -n kube-system describe deploy/aws-load-balancer-controller || true
    kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller -o wide || true
    kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50 || true
    return 1
  fi
}

# --- 4. ACM certificate (prod only) ------------------------------------------
# NOTE: this function's stdout is captured by the caller ($(issue_certificate)),
# so ONLY the final `echo "${cert_arn}"` may write to stdout. Every aws call here
# must send its own output to stderr or /dev/null, or it corrupts CERT_ARN (and
# thus the rendered ingress YAML).
issue_certificate() {
  local fqdn="flyte.${DOMAIN_NAME}" cert_arn
  cert_arn="$(aws acm list-certificates --region "${AWS_REGION}" \
    --query "CertificateSummaryList[?DomainName=='${fqdn}'].CertificateArn | [0]" \
    --output text)"
  if [[ -z "${cert_arn}" || "${cert_arn}" == "None" ]]; then
    log "requesting ACM cert for ${fqdn}"
    cert_arn="$(aws acm request-certificate --region "${AWS_REGION}" \
      --domain-name "${fqdn}" --validation-method DNS \
      --query CertificateArn --output text)"
    sleep 10
    # Create the DNS validation record in Route 53. Its ChangeInfo JSON must NOT
    # leak to stdout (would be captured into CERT_ARN) -> redirect to stderr.
    read -r vname vvalue < <(aws acm describe-certificate --region "${AWS_REGION}" \
      --certificate-arn "${cert_arn}" \
      --query "Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Value]" \
      --output text)
    aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" \
      --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${vname}\",\"Type\":\"CNAME\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"${vvalue}\"}]}}]}" \
      >&2
  fi
  log "waiting for cert validation"
  aws acm wait certificate-validated --region "${AWS_REGION}" --certificate-arn "${cert_arn}" >&2
  echo "${cert_arn}"
}

# --- 5. render config + install Flyte via the resolver -----------------------
# CERT_ARN + INGRESS_HOST are consumed by render-config.sh, which emits the
# single, complete ingress block (host + ALB annotations) — one source of truth,
# one `ingress:` key.
export CERT_ARN=""
if [[ "${PROD_MODE}" == "true" ]]; then
  install_lb_controller
  CERT_ARN="$(issue_certificate)"
  # Guard: CERT_ARN must be a single clean ARN. If any captured call leaked
  # output into it, fail loudly here instead of as an opaque YAML parse error.
  if [[ ! "${CERT_ARN}" =~ ^arn:aws:acm:[a-z0-9-]+:[0-9]+:certificate/[a-z0-9-]+$ ]]; then
    echo "ERROR: issue_certificate returned a malformed CERT_ARN:" >&2
    printf '%s\n' "${CERT_ARN}" >&2
    exit 1
  fi
  export CERT_ARN
  export INGRESS_HOST="flyte.${DOMAIN_NAME}"
fi

log "rendering Flyte config"
CONFIG_FILE="$(mktemp)"
DB_HOST="${DB_HOST}" DB_PORT="${DB_PORT:-5432}" DB_NAME="${DB_NAME:-flyte}" \
DB_USER="${DB_USER:-flyte}" S3_BUCKET="${S3_BUCKET}" AWS_REGION="${AWS_REGION}" \
INGRESS_HOST="${INGRESS_HOST:-}" CERT_ARN="${CERT_ARN}" \
COGNITO_USER_POOL_ARN="${COGNITO_USER_POOL_ARN:-}" COGNITO_CLIENT_ID="${COGNITO_CLIENT_ID:-}" \
COGNITO_DOMAIN_PREFIX="${COGNITO_DOMAIN_PREFIX:-}" COGNITO_ISSUER="${COGNITO_ISSUER:-}" \
COGNITO_CLI_CLIENT_ID="${COGNITO_CLI_CLIENT_ID:-}" \
  "${REPO_ROOT}/scripts/render-config.sh" > "${CONFIG_FILE}"

log "installing Flyte via resolver"
INSTALL_MODE="${INSTALL_MODE:-auto}" \
CLUSTER_NAME="${CLUSTER_NAME}" AWS_REGION="${AWS_REGION}" \
CONFIG_FILE="${CONFIG_FILE}" POD_IDENTITY_ROLE_ARN="${FLYTE_S3_ROLE_ARN}" \
  "${REPO_ROOT}/scripts/resolve-install.sh"

# The console SPA serves /v2, not /healthz, so its ALB target group needs its own
# health-check path. The chart exposes no per-service annotation, and the
# ingress-wide /healthz would fail the console; patch the console Service
# directly (the AWS LBC reads health-check annotations per Service).
if [[ "${PROD_MODE}" == "true" ]]; then
  log "setting console ALB health-check path (/v2)"
  kubectl -n "${NAMESPACE}" annotate service \
    -l app.kubernetes.io/component=console \
    alb.ingress.kubernetes.io/healthcheck-path=/v2 --overwrite || true
fi

# --- 6. Route 53 alias to the ingress ALB (prod only) ------------------------
if [[ "${PROD_MODE}" == "true" ]]; then
  log "waiting for ingress ALB hostname"
  alb_host=""
  for _ in $(seq 1 60); do
    alb_host="$(kubectl -n "${NAMESPACE}" get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    [[ -n "${alb_host}" ]] && break
    sleep 15
  done
  [[ -z "${alb_host}" ]] && { echo "ingress ALB never became ready" >&2; exit 1; }
  log "pointing flyte.${DOMAIN_NAME} at ${alb_host}"
  # ALB hosted zone id lookup via the LB describe (alias needs the ALB's zone).
  alb_zone="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
    --query "LoadBalancers[?DNSName=='${alb_host}'].CanonicalHostedZoneId | [0]" --output text)"
  aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"flyte.${DOMAIN_NAME}\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"${alb_zone}\",\"DNSName\":\"${alb_host}\",\"EvaluateTargetHealth\":false}}}]}"
fi

log "bootstrap complete"

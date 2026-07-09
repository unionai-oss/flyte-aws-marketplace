#!/usr/bin/env bash
# Render the per-deployment add-on configuration document from simple inputs.
#
# This is the ONE place that maps friendly inputs -> the nested flyte-binary
# configurationValues shape. Its output is consumed identically by BOTH install
# paths (see resolve-install.sh):
#   * add-on path : passed to `aws eks create-addon --configuration-values`
#   * helm path   : passed to `helm install -f`
# so the two paths install byte-equivalent config.
#
# Inputs are environment variables (CloudFormation passes these through, or set
# them by hand for local dev). Output: a YAML document on stdout.
#
# Required:
#   DB_HOST         Aurora writer endpoint
#   S3_BUCKET       provisioned bucket name (used for both metadata + user data)
#   AWS_REGION      region of the bucket/cluster
# Optional:
#   DB_PORT         (default 5432)
#   DB_NAME         (default flyte)
#   DB_USER         (default flyte)
#   DB_PASSWORD_PATH(default /etc/db/secret/password)
#   INGRESS_HOST    if set, enables ALB ingress at this host (prod mode)
#   CERT_ARN        ACM cert for INGRESS_HOST (required with INGRESS_HOST)
# Auth (all four enable the secure 3-ingress split; omit for an open ingress):
#   COGNITO_USER_POOL_ARN   Cognito user pool ARN (browser SSO via ALB)
#   COGNITO_CLIENT_ID       Cognito app client id (confidential, browser)
#   COGNITO_DOMAIN_PREFIX   Cognito hosted-UI domain prefix
#   COGNITO_ISSUER          https://cognito-idp.<region>.amazonaws.com/<poolId>
#   COGNITO_CLI_CLIENT_ID   public PKCE client id (enables SDK/CLI auth discovery
#                           via runs.authMetadata)
#   HTTP_SERVICE_NAME       backend http service name for the Bearer condition
#                           (default flyte-flyte-binary-http)
#   ALB_GROUP_NAME          shared ALB IngressGroup name (default flyte)
set -euo pipefail

: "${DB_HOST:?DB_HOST is required}"
: "${S3_BUCKET:?S3_BUCKET is required}"
: "${AWS_REGION:?AWS_REGION is required}"

DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-flyte}"
DB_USER="${DB_USER:-flyte}"
DB_PASSWORD_PATH="${DB_PASSWORD_PATH:-/etc/db/secret/password}"

cat <<YAML
flyte-binary:
  flyte-core-components:
    runs:
      storagePrefix: "s3://${S3_BUCKET}"
YAML

# authMetadata advertises the external IdP so the SDK/CLI can discover where to
# log in (served at /.well-known/oauth-authorization-server + AuthMetadataService,
# which the wellknown ingress exposes unauthenticated). Uses the public PKCE
# client. Passed through verbatim by the chart's flyte-core-components block.
if [[ -n "${COGNITO_ISSUER:-}" && -n "${COGNITO_CLI_CLIENT_ID:-}" ]]; then
cat <<YAML
      authMetadata:
        externalAuthServerBaseUrl: "${COGNITO_ISSUER}"
        # Cognito serves OIDC discovery at /.well-known/openid-configuration but
        # NOT the RFC 8414 /.well-known/oauth-authorization-server (Flyte's
        # default), which 400s. Override the path so the proxy fetches the doc
        # Cognito actually serves.
        externalMetadataUrl: .well-known/openid-configuration
        flyteClient:
          clientId: "${COGNITO_CLI_CLIENT_ID}"
          redirectUri: http://localhost:53593/callback
          scopes:
            - openid
            - email
            - profile
YAML
fi

cat <<YAML
  configuration:
    database:
      postgres:
        host: "${DB_HOST}"
        port: ${DB_PORT}
        dbname: "${DB_NAME}"
        username: "${DB_USER}"
        passwordPath: "${DB_PASSWORD_PATH}"
    storage:
      metadataContainer: "${S3_BUCKET}"
      providerConfig:
        s3:
          region: "${AWS_REGION}"
          authType: iam
YAML

if [[ -n "${INGRESS_HOST:-}" && -n "${CERT_ARN:-}" ]]; then
  HTTP_SVC="${HTTP_SERVICE_NAME:-flyte-flyte-binary-http}"
  GROUP_NAME="${ALB_GROUP_NAME:-flyte}"
  # Emitted here (not appended by the caller) so the config has exactly one
  # `ingress:` key — helm's YAML->JSON rejects duplicate mapping keys.
cat <<YAML
  ingress:
    create: true
    host: "${INGRESS_HOST}"
    commonAnnotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
      alb.ingress.kubernetes.io/certificate-arn: "${CERT_ARN}"
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
      # Same group.name on all three ingresses -> one shared ALB.
      alb.ingress.kubernetes.io/group.name: "${GROUP_NAME}"
      # v2's http port is gRPC/Connect (GET / -> 404); health-check the API
      # backend on /healthz. The console TG gets /v2 via a per-service annotation
      # applied by bootstrap.sh.
      alb.ingress.kubernetes.io/healthcheck-path: /healthz
      alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
      alb.ingress.kubernetes.io/success-codes: "200"
YAML
  if [[ -n "${COGNITO_USER_POOL_ARN:-}" && -n "${COGNITO_ISSUER:-}" ]]; then
    # Secure mode: three ingresses merged onto ONE ALB via group.name, ordered by
    # group.order (lower = evaluated first):
    #   10 wellknown  — unauthenticated auth-discovery (clients need it pre-token)
    #   20 api-jwt    — flyteidl2.* with `Authorization: Bearer` -> ALB validates
    #                   the Cognito JWT (signature/iss/exp) and rejects invalid
    #   30 http       — catch-all: console /v2 + browser cookie API, Cognito SSO
    # Browser XHR carries the session cookie (no Bearer header) so it misses the
    # api-jwt condition and falls through to the SSO-gated http ingress.
cat <<YAML
    httpAnnotations:
      alb.ingress.kubernetes.io/group.order: "30"
      alb.ingress.kubernetes.io/auth-type: cognito
      alb.ingress.kubernetes.io/auth-scope: "openid email"
      alb.ingress.kubernetes.io/auth-on-unauthenticated-request: authenticate
      alb.ingress.kubernetes.io/auth-idp-cognito: '{"userPoolARN":"${COGNITO_USER_POOL_ARN}","userPoolClientID":"${COGNITO_CLIENT_ID}","userPoolDomain":"${COGNITO_DOMAIN_PREFIX}"}'
    apiJwtIngress:
      enabled: true
      annotations:
        alb.ingress.kubernetes.io/group.order: "20"
        alb.ingress.kubernetes.io/jwt-validation: '{"jwksEndpoint":"${COGNITO_ISSUER}/.well-known/jwks.json","issuer":"${COGNITO_ISSUER}"}'
        alb.ingress.kubernetes.io/conditions.${HTTP_SVC}: '[{"field":"http-header","httpHeaderConfig":{"httpHeaderName":"Authorization","values":["Bearer *"]}}]'
    wellknownIngress:
      enabled: true
      annotations:
        alb.ingress.kubernetes.io/group.order: "10"
YAML
  fi
fi

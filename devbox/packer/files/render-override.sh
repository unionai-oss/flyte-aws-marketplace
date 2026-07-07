#!/bin/bash
set -euo pipefail
source /etc/flyte-devbox/render.env

if [ "$PROD_MODE" = "1" ]; then
  PW=$(aws secretsmanager get-secret-value \
         --secret-id "$DB_SECRET_ARN" --region "$RENDER_REGION" \
         --query SecretString --output text \
       | python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])')
  cat > /etc/flyte-devbox/config.yaml <<EOF
runs:
  storagePrefix: s3://$BUCKET_NAME
  database:
    postgres:
      host: $DB_HOST
      port: $DB_PORT
      dbName: $DB_NAME
      user: $DB_USER
      username: $DB_USER
      password: "$PW"
      options: sslmode=require
  authMetadata:
    externalAuthServerBaseUrl: $COGNITO_ISSUER
    externalMetadataUrl: .well-known/openid-configuration
    flyteClient:
      clientId: $COGNITO_PKCE_CLIENT_ID
      redirectUri: http://localhost:8089/callback
      scopes:
      - openid
      - profile
storage:
  type: stow
  stow:
    kind: s3
    config:
      region: $RENDER_REGION
      auth_type: iam
      endpoint: ""
      disable_ssl: false
      v2_signing: false
      access_key_id: ""
      secret_key: ""
  container: $BUCKET_NAME
  signedURL:
    stowConfigOverride:
      endpoint: ""
plugins:
  k8s:
    default-env-vars:
    - AWS_REGION: $RENDER_REGION
    - AWS_DEFAULT_REGION: $RENDER_REGION
    - _U_EP_OVERRIDE: flyte-binary-http.flyte:8090
    - _U_INSECURE: "true"
    - _U_USE_ACTIONS: "1"
internalApps:
  # Public app URLs: https://<app>.apps.<Domain> via the ALB wildcard. Overrides
  # the devbox image defaults (localhost:30081) so flyte stamps the real external
  # host into each app's status.ingress.public_url.
  baseDomain: apps.${FLYTE_DOMAIN}
  scheme: https
  ingressAppsPort: 443
  defaultEnvVars:
  - AWS_REGION: $RENDER_REGION
  - AWS_DEFAULT_REGION: $RENDER_REGION
  - _U_EP_OVERRIDE: flyte-binary-http.flyte:8090
  - _U_INSECURE: "true"
  - _U_USE_ACTIONS: "1"
EOF
  echo "rendered Prod override (S3=$BUCKET_NAME RDS=$DB_HOST apps=apps.${FLYTE_DOMAIN})"
  exit 0
fi

# Eval mode: point signed URLs at the current public hostname.
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
HOST=$(curl -sH "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-hostname)
if [ -z "$HOST" ]; then
  echo "no public hostname; leaving override empty (UI/local-only)"
  : > /etc/flyte-devbox/config.yaml
  exit 0
fi
cat > /etc/flyte-devbox/config.yaml <<EOF
storage:
  signedURL:
    stowConfigOverride:
      endpoint: http://$HOST:30002
EOF

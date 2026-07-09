#!/bin/bash
# Point Knative's app-serving domain at <app>.apps.<Domain> so app public_urls
# resolve through the ALB wildcard record instead of the default 'localhost'.
#
# Runs on every devbox (re)start (via flyte-appdomain.service): the k3s 'flyte'
# addon reseeds the knative-serving/config-domain ConfigMap to 'localhost' each
# time the cluster comes up, so we re-apply our override after the CM appears.
set -euo pipefail
source /etc/flyte-devbox/render.env

# Prod mode only; needs a real domain.
[ "${PROD_MODE:-0}" = "1" ] || exit 0
[ -n "${FLYTE_DOMAIN:-}" ] && [ "${FLYTE_DOMAIN}" != "none" ] || exit 0

APPS_DOMAIN="apps.${FLYTE_DOMAIN}"
K="docker exec flyte-devbox kubectl"

# Wait for the config-domain CM to exist (cluster + knative addon up), then set
# our domain as the sole default and drop the seeded 'localhost' key.
for _ in $(seq 1 120); do
  if $K -n knative-serving get configmap config-domain >/dev/null 2>&1; then
    $K -n knative-serving patch configmap config-domain --type merge \
      -p "{\"data\":{\"${APPS_DOMAIN}\":\"\"}}" >/dev/null 2>&1 || true
    # Remove the default 'localhost' key if present (ignore if already gone) so
    # there is exactly one default domain.
    $K -n knative-serving patch configmap config-domain --type json \
      -p '[{"op":"remove","path":"/data/localhost"}]' >/dev/null 2>&1 || true
    echo "[flyte-appdomain] config-domain set to ${APPS_DOMAIN}"
    exit 0
  fi
  sleep 5
done

echo "[flyte-appdomain] config-domain CM not found after wait; giving up" >&2
exit 0

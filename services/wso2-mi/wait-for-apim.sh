#!/bin/sh
set -eu

APIM_BASE_URL="${WSO2_APIM_URL:-https://wso2-apim:9443}"
ATTEMPTS="${APIM_WAIT_ATTEMPTS:-120}"
SLEEP_SECONDS="${APIM_WAIT_INTERVAL_SECONDS:-5}"

echo "[mi-entrypoint] Waiting for API Manager at ${APIM_BASE_URL}/services/Version"

attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
  if wget --no-check-certificate -qO- "${APIM_BASE_URL}/services/Version" >/dev/null 2>&1; then
    echo "[mi-entrypoint] API Manager is ready. Starting WSO2 Integrator: MI."
    exec /home/wso2carbon/docker-entrypoint.sh "$@"
  fi
  echo "[mi-entrypoint] API Manager not ready (${attempt}/${ATTEMPTS})"
  attempt=$((attempt + 1))
  sleep "$SLEEP_SECONDS"
done

echo "[mi-entrypoint] API Manager did not become ready." >&2
exit 1

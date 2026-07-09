#!/usr/bin/env bash
set -u

PORTAL_URL="http://localhost:8080/portal-status"

for attempt in $(seq 1 60); do
  printf '[portal-check] Attempt %d/60: ' "${attempt}"

  STATUS="$(
    curl -fsS \
      --connect-timeout 2 \
      --max-time 5 \
      "${PORTAL_URL}" \
      2>/dev/null ||
      true
  )"

  if [[ -z "${STATUS}" ]]; then
    echo "no response"
  elif ! jq -e . <<<"${STATUS}" >/dev/null 2>&1; then
    echo "non-JSON response"
    printf '%s\n' "${STATUS}"
  elif jq -e '.status == "READY"' \
      <<<"${STATUS}" >/dev/null 2>&1
  then
    echo "READY"
    jq . <<<"${STATUS}"
    exit 0
  else
    current_status="$(
      jq -r '.status // "UNKNOWN"' \
        <<<"${STATUS}"
    )"

    echo "status=${current_status}"
  fi

  sleep 2
done

echo
echo "[portal-check][FAIL] Portal did not become READY."

echo
echo "Matching containers:"
docker ps -a \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' |
  grep -E 'demo-portal|portal' ||
  true

portal_container="$(
  docker ps -a \
    --format '{{.Names}}' |
    grep -E 'demo-portal|portal' |
    head -n 1
)"

if [[ -n "${portal_container}" ]]; then
  echo
  echo "Last 200 log lines from ${portal_container}:"
  docker logs \
    --tail=200 \
    "${portal_container}" ||
    true
fi

exit 1

#!/usr/bin/env bash
set -Eeuo pipefail

GATEWAY="${GATEWAY:-http://localhost:8288}"
PATH_TO_CALL="${PATH_TO_CALL:-/secure-transaction-risk/v1/assessments}"
COUNT="${COUNT:-24}"
AUTH_HEADERS=()
if [[ -n "${OBS_ACCESS_TOKEN:-}" ]]; then
  AUTH_HEADERS=(-H "Authorization: Bearer ${OBS_ACCESS_TOKEN}")
elif [[ -n "${OBS_AUTHORIZATION:-}" ]]; then
  AUTH_HEADERS=(-H "Authorization: ${OBS_AUTHORIZATION}")
fi

success=0
failure=0
for i in $(seq 1 "$COUNT"); do
  if command -v uuidgen >/dev/null 2>&1; then
    CID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  else
    CID="$(openssl rand -hex 16)"
  fi
  case $((i % 4)) in
    0) COUNTRY=BR; CURRENCY=BRL; PARTNER=partner-br-retail; LAT=-23.5505; LON=-46.6333 ;;
    1) COUNTRY=MX; CURRENCY=MXN; PARTNER=partner-mx-fintech; LAT=19.4326; LON=-99.1332 ;;
    2) COUNTRY=CO; CURRENCY=COP; PARTNER=partner-co-commerce; LAT=4.7110; LON=-74.0721 ;;
    3) COUNTRY=AR; CURRENCY=ARS; PARTNER=partner-ar-wallet; LAT=-34.6037; LON=-58.3816 ;;
  esac
  TRACE_ID="$(openssl rand -hex 16)"
  SPAN_ID="$(openssl rand -hex 8)"
  BODY="$(cat <<JSON
{"transactionId":"TX-OBS-${i}","partnerId":"${PARTNER}","msisdn":"+5511999$(printf '%07d' "$i")","amount":$((i*100)),"currency":"${CURRENCY}","expectedCountry":"${COUNTRY}","device":{"latitude":${LAT},"longitude":${LON}},"partialResponsePolicy":"ALLOW_DEGRADED"}
JSON
)"
  code="$(curl -skS -o "/tmp/telco-obs-response-${i}.json" -w '%{http_code}' \
    -X POST "${GATEWAY}${PATH_TO_CALL}" \
    "${AUTH_HEADERS[@]}" \
    -H 'Content-Type: application/json' \
    -H "activityID: ${CID}" \
    -H "X-Correlation-ID: ${CID}" \
    -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" \
    -H "organization-id: ${COUNTRY}" \
    -H "source-id: ${PARTNER}" \
    -H 'application-id: regional-portal' \
    --data-binary "$BODY" || true)"
  printf '%s trace=%s country=%s partner=%s HTTP %s\n' "$CID" "$TRACE_ID" "$COUNTRY" "$PARTNER" "$code"
  if [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    success=$((success+1))
  else
    failure=$((failure+1))
    cat "/tmp/telco-obs-response-${i}.json" 2>/dev/null || true
    echo
  fi
  sleep 0.35
done
printf 'Traffic summary: success=%d failure=%d total=%d\n' "$success" "$failure" "$COUNT"
(( success > 0 ))

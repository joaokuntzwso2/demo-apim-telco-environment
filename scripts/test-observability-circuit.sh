#!/usr/bin/env bash
set -euo pipefail

for cmd in curl jq openssl awk; do command -v "$cmd" >/dev/null || { echo "Missing command: $cmd" >&2; exit 1; }; done

BASE="${BACKEND_OBSERVER_URL:-http://localhost:8091}"
BACKEND="${OBS_CIRCUIT_BACKEND:-crm}"
TARGET_PATH="${OBS_CIRCUIT_TARGET_PATH:-/health}"

cleanup() {
  curl -fsS -X DELETE "${BASE}/__admin/faults/${BACKEND}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

curl -fsS -X POST "${BASE}/__admin/faults/${BACKEND}?mode=error" | jq -e '.status == "ENABLED"' >/dev/null

for i in $(seq 1 6); do
  CID="circuit-${BACKEND}-$(date +%s)-${i}-$RANDOM"
  TRACE_ID="$(openssl rand -hex 16)"
  SPAN_ID="$(openssl rand -hex 8)"
  CODE="$(curl -sS -o /tmp/telco-circuit-response.json -w '%{http_code}' \
    "${BASE}/backend/${BACKEND}${TARGET_PATH}" \
    -H 'x-observer-component-test: true' \
    -H "activityID: ${CID}" \
    -H "X-Correlation-ID: ${CID}" \
    -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" || true)"
  [[ "$CODE" == "503" || "$CODE" == "504" ]] || {
    echo "FAIL: expected injected failure from ${BACKEND}, received HTTP ${CODE}." >&2
    cat /tmp/telco-circuit-response.json >&2 || true
    exit 1
  }
done

curl -fsS "${BASE}/metrics" \
  | awk -v backend="$BACKEND" '
      $0 ~ "^telco_backend_circuit_state\\{backend=\"" backend "\"\\} 2$" { found=1 }
      END { exit found ? 0 : 1 }
    ' || {
      echo "FAIL: ${BACKEND} circuit did not reach OPEN=2." >&2
      curl -fsS "${BASE}/metrics" | grep 'telco_backend_circuit_state' >&2 || true
      exit 1
    }

echo "PASS: ${BACKEND} circuit reached OPEN."
curl -fsS -X DELETE "${BASE}/__admin/faults/${BACKEND}" | jq -e '.status == "DISABLED"' >/dev/null

sleep 11
curl -fsS "${BASE}/metrics" \
  | awk -v backend="$BACKEND" '
      $0 ~ "^telco_backend_circuit_state\\{backend=\"" backend "\"\\} 1$" { found=1 }
      END { exit found ? 0 : 1 }
    ' || {
      echo "FAIL: ${BACKEND} circuit did not enter HALF_OPEN=1 after reset timeout." >&2
      curl -fsS "${BASE}/metrics" | grep 'telco_backend_circuit_state' >&2 || true
      exit 1
    }
echo "PASS: ${BACKEND} circuit reached HALF_OPEN."

CID="circuit-recovery-${BACKEND}-$(date +%s)-$RANDOM"
TRACE_ID="$(openssl rand -hex 16)"
SPAN_ID="$(openssl rand -hex 8)"
RECOVERY_CODE="$(curl -sS -o /tmp/telco-circuit-recovery.json -w '%{http_code}' \
  "${BASE}/backend/${BACKEND}${TARGET_PATH}" \
  -H 'x-observer-component-test: true' \
  -H "activityID: ${CID}" \
  -H "X-Correlation-ID: ${CID}" \
  -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" || true)"
[[ "$RECOVERY_CODE" =~ ^2[0-9][0-9]$ ]] || {
  echo "FAIL: ${BACKEND} half-open recovery returned HTTP ${RECOVERY_CODE}." >&2
  cat /tmp/telco-circuit-recovery.json >&2 || true
  exit 1
}

curl -fsS "${BASE}/metrics" \
  | awk -v backend="$BACKEND" '
      $0 ~ "^telco_backend_circuit_state\\{backend=\"" backend "\"\\} 0$" { found=1 }
      END { exit found ? 0 : 1 }
    ' || {
      echo "FAIL: ${BACKEND} circuit did not return to CLOSED=0." >&2
      exit 1
    }

rm -f /tmp/telco-circuit-response.json /tmp/telco-circuit-recovery.json
echo "PASS: ${BACKEND} circuit recovered through HALF_OPEN and returned to CLOSED."
